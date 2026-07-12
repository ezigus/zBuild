# ADR-001: Plugin Contract

**Status:** Accepted
**Date:** 2026-05-24
**Amended by:** ADR-042 — a stage's flow-name need not equal its manifest `id`; stage→plugin resolution is role-then-id everywhere (leaf, cycle, parallel).

## Context

zBuild is a plugin-based framework. The engine in `core/` is intentionally small; all behavior (LLM agents, non-AI integrations, recovery strategies, orchestrators, claim coordinators, daemons) is delivered by plugins. For this to be sustainable, the seam between engine and plugins must be a precise contract — not a convention.

Without a formal contract:
- Plugins reach into engine internals; refactors break the world.
- Lifecycle ordering is implicit; race conditions appear at scale.
- Discovery is ad-hoc; plugin sets drift between environments.
- Errors are unstructured; recovery plugins can't classify.

## Decision

Every plugin lives in `plugins/<kind>/<name>/` and provides a `manifest.yaml` plus a `plugin.sh` implementing required lifecycle hooks.

### Manifest schema

```yaml
id: <kebab-case-globally-unique>
name: <human-readable>
kind: agent | tool | recovery | orchestrator | claim-coordinator | daemon
convergence: gate | advisory   # OPTIONAL — ADR-040 §5/§7 convergence marker
version: <semver>
description: |
  <one paragraph>

# Optional doc fields — consumed by the doc-generator (e.g., `zbuild plugin list`).
# If declared, each must be a non-empty string; an empty value fails manifest validation.
summary: <one-line synopsis>        # OPTIONAL
usage: |
  <invocation notes>                # OPTIONAL

hooks:
  init: <function-name>           # called once per pipeline run, before any run
  run: <function-name>            # called by orchestrator (or kind-specific)
  finalize: <function-name>       # called after all cycles complete
  cleanup: <function-name>        # called on abnormal exit (kill, abort)

requires:
  core: [redaction, event-bus, state, locks, github, ...]
  plugins: [<plugin-id>, ...]
  # NOTE (ADR-043): a `kind: agent` plugin still declares `requires.core:
  # [redaction]` — redaction is still REQUIRED — but it no longer needs to CALL
  # `apply_scope_redaction` itself. As of ADR-043 the router redacts by
  # construction in `route_to_model` / `route_to_model_loop`. The declaration
  # now asserts "this plugin's prompts are redaction-governed", enforced
  # centrally by the router rather than per-plugin.

provides:
  artifact_type: <type>
  schema_version: <int>

config:
  <key>: <default>

inputs:
  - name: <name>
    type: <type>

outputs:
  - name: <name>
    path: <template-using-${vars}>
    type: <type>

state:
  persisted: [<keys plugins write via core/state>]
  reconstructed: [<keys recomputed at init on resume>]
```

### Required hooks per kind

| Kind | Required entry point | Inputs | Output |
|---|---|---|---|
| `agent` | `run` | scope manifest, input artifact, tier | structured artifact (typed) |
| `tool` | `run` | typed args | exit code + structured stdout/stderr |
| `recovery` | `classify`, `act` | error context | action verb (`retry`, `backtrack`, `escalate`, `abort`) |
| `orchestrator` | `run` | upstream artifacts | downstream artifact(s) + verdict |
| `claim-coordinator` | `claim`, `release`, `heartbeat`, `list_claims` | issue id | acquired flag + lease id |
| `daemon` | `tick` | poll interval | events to bus |

All kinds may implement `init`, `finalize`, `cleanup`.

### The `convergence:` marker (optional — ADR-040)

A gate/lens plugin MAY declare a top-level `convergence:` field — the authoritative mechanical-vs-advisory
discriminator for the convergence-path invariant (ADR-040 §5/§7), independent of `kind:`:

- `convergence: gate` — mechanical, **blocks** convergence (included in the gate-aggregator's
  roster-driven must-pass set). Allowed for `kind: tool` OR `kind: agent` (e.g. `acceptance-gate` is
  `kind: agent` yet mechanical — it makes no `model.route` call).
- `convergence: advisory` — **never** blocks; must not appear on a must-pass / `exit_when` path
  (lenses, review-aggregator).
- *absent* — not a convergence gate; excluded from the must-pass set (work stages, the
  gate-aggregator itself).

### Hook function signature

All lifecycle hooks (`init`, `run`/kind-entry, `finalize`, `cleanup`) receive the same two positional arguments from `plugin_hook_call` (see `core/plugin-registry/registry.sh`):

```
<hook>(stage_id, state_file)
```

- `$1` — `stage_id` (string, informational; most plugins ignore it).
- `$2` — `state_file` (absolute path to `pipeline-state.json`). Plugins derive `state_dir = dirname($2)` and `artifacts_dir = $state_dir/artifacts`.

Run-time context (goal text, issue number, run id, target platform, scope manifest path) is passed via env vars exported by the runner — never via positional args. The current set:

| Env var | Set by | Available to |
|---|---|---|
| `ZBUILD_GOAL` | runner | all hooks |
| `ZBUILD_ISSUE` | runner | all hooks (empty string when absent) |
| `ZBUILD_RUN_ID` | runner | all hooks |
| `ZBUILD_TARGET_PLATFORM` | runner (fanout strategy) | role-resolved hooks only |

Plugins MUST use the defensive read `local state_file="${2:-}"` and return rc=2 if `state_file` is empty, so config errors surface distinctly from runtime failures. Plugins MAY split their hook into an outer adapter (`<plugin>_run`) and an inner unit-testable function with explicit path args (e.g., `_security_lens_run_inner`) — the outer is the contract; the inner is for tests.

### Lifecycle ordering

For each plugin discovered in a run:
1. `init` — once per pipeline run, before any `run`/kind-entry. Reserve resources, validate config.
2. Kind-specific entry — possibly many invocations.
3. `finalize` — once at end-of-run; flush state, emit summary event.
4. `cleanup` — on abnormal exit only; release locks, write tombstone event.

The engine enforces ordering; plugins MUST be idempotent across re-runs of `init` (in case of resume).

### Error semantics

Plugin exit codes:
- `0` — success.
- `1` — recoverable error. Engine routes to `kind: recovery` plugins for classification + action.
- `2` — fatal. Engine logs, emits `plugin.error`, aborts the run (after `cleanup`).

Plugins MAY emit `recovery.suggestion` events with structured payloads:
```json
{ "category": "auth|api|context|build|unknown", "suggested_action": "retry|backtrack|escalate" }
```
The engine forwards these to recovery plugins and respects the action verb returned.

### Fail-closed scanner contract

If a plugin declares `provides.artifact_type` but no artifact exists at `outputs[].path` after `run` completes with exit 0, the engine emits a synthetic blocking finding. Absent evidence IS blocking evidence. (Keepers §C.4.)

### Discovery + lockfile

- `plugins/<kind>/<name>/manifest.yaml` is discovered via filesystem glob at engine startup.
- A discovered set is captured in `~/.zbuild/state/plugins.lock` (manifest hashes + paths) on first successful run.
- Subsequent runs validate against the lockfile; checksum mismatch → warn by default; `strict_plugin_lock: true` config setting → fail.
- `config/plugins.disabled` (line-delimited plugin IDs) excludes plugins per-run.

### Cross-plugin dependencies

A plugin's `requires.plugins` list is enforced at discovery time: the engine refuses to start if a required plugin is missing or disabled. Cyclic dependencies are detected and refused.

## Consequences

**Good:**
- Refactor-safe: engine internals can change as long as the contract holds.
- New plugin authors have an explicit checklist (manifest + hooks + tests).
- Lockfile gives deployments reproducibility ("works on Alice's machine").
- Fail-closed scanner pattern generalizes: every typed artifact has a guaranteed signal.

**Bad:**
- Manifest authorship is friction. The schema must stay small and well-documented.
- Lockfile drift is real; teams need to know how to regenerate it.
- Cross-plugin dependencies invite tight coupling if abused. Code review enforces "plugins should be small and independent."

**Open questions deferred:**
- Versioning across breaking manifest changes — start with `schema_version` in manifest; bump policy TBD.
- Hot-reload of plugins during a long-running pipeline — out of scope for Phase 0.
- Plugin **bootstrap/teardown** lifecycle (`zbuild bootstrap` / `zbuild teardown` commands and their interaction with plugin `init`/`cleanup` hooks at CI boundary) is deferred to Phase 1.  See [PHASE-DEFERRALS.md](PHASE-DEFERRALS.md) and ADR-010 §Implementation Notes.

## Implementation Notes (Phase 0.5 — issue #291)

- **Aggregator role/type binding (Phase 1, issue #1177).** A stage's top-level `convergence:` marker
  declares its aggregator/gate TYPE and binds to a convergence role: `gate-aggregator` (role
  `gate_aggregator`) declares `convergence: gate`; `review-aggregator` (role `review_aggregator`)
  declares `convergence: advisory`. The typed-aggregator preflight (ADR-040 §Phase 1) resolves a
  template stage's marker id-first, then by `provides.role` — the same resolution the roster-driven
  gate-aggregator uses — so role-bound members (e.g. `lens-*` → role `review_lens`) resolve correctly.
- **Manifest validation** is partially implemented at `core/plugin-registry/registry.sh:117–142`. As of 2026-05-26 it enforces only the 4 required identity fields (`id/name/kind/version`) plus a grep-based check that agent-plugins declare `requires.core: [redaction]`. Full YAML-structural validation of `hooks`-per-kind, `requires.core` as a structured list, `provides.artifact_type`, and `state.persisted/reconstructed` is tracked by **#287** + **#294**.
- **Lockfile** at `registry.sh:204–238` currently hashes `manifest.yaml` only. Hashing `plugin.sh` and any auxiliary files (and reverifying before `source`) is tracked by **#290**. Until that lands, a tampered `plugin.sh` with unchanged manifest will pass verification.
- **Fail-closed artifact-presence scanner** referenced in this ADR is not yet implemented; tracked by **#288**. Plugins declaring `provides.artifact_type` whose `outputs[].path` is missing after a 0-exit run currently emit no synthetic blocking finding.
- **Test coverage:** `tests/unit/core-plugin-registry-test.sh` and `tests/integration/core-plugin-registry-test.sh` cover the current 4-field validator. Coverage for the deferred items lives in the tracking issues above.

## References

- [KEEPERS.md](../KEEPERS.md) §A (stage dispatch), §F (personas as agent plugins).
- [ARCHITECTURE.md](../ARCHITECTURE.md) §2 (plugin contract), §3 (data flow).
- `legacy/scripts/lib/skill-registry.sh` — the only plugin-shaped surface in the upstream today; informs the manifest design but is narrower (prompt fragments only).
