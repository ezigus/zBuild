# ADR-001: Plugin Contract

**Status:** Accepted
**Date:** 2026-05-24
**Amended by:** ADR-042 — a stage's flow-name need not equal its manifest `id`; stage→plugin resolution is role-then-id everywhere (leaf, cycle, parallel).
**Amended:** 2026-08-09 (#1820, ADR-054) — hook lifecycle corrected: only run and cleanup are active at the stage-dispatch layer; init and finalize are never called there. rc table superseded: plugin rc is binary (0 success, 1 error); the rc=1→recovery routing never existed. See ADR-054.
**Amended:** 2026-08-12 (#1768, ADR-055 §1) — the manifest `inputs:`/`outputs:` shape is corrected. The example used `name:` where the engine has always read `id:`, and predates the source vocabulary entirely. A consumer now declares the artifact **name** it needs and nothing else — no producer stage, no path, no type — and the engine resolves it to the single stage in the flow producing it. ADR-055 owns the data surface; this ADR shows the shape only.
**Amended:** 2026-08-20 (#1900) — **`kind: recovery` is retired**, not merely unimplemented. It is removed from `ZBUILD_PLUGIN_KINDS`, its `classify`/`act` hooks are deleted, and the three never-emitted `recovery.*` event names are removed from `config/event-schema.json`. ADR-054 §6 superseded it: `disposition` covers `retry`/`escalate`/`abort` and ADR-045's `route_back` covers `backtrack`, and ADR-054 inverted its premise by moving retry policy out of plugins and into the engine. Five kinds remain in this document (`persona`, #1304, is a sixth the prose here never listed). See §"Error semantics".

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
kind: agent | tool | orchestrator | claim-coordinator | daemon
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
  run: <function-name>            # called by orchestrator (or kind-specific) — REQUIRED
  cleanup: <function-name>        # called on abnormal exit (kill, abort) — OPTIONAL

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
  events:                       # OPTIONAL — amended 2026-08-17 (#1717)
    - <namespace>.<event>       # every event THIS plugin emits in its own namespace

config:
  <key>: <default>

inputs:                       # amended 2026-08-12 (#1768, ADR-055 §1)
  - id: <artifact-name>       # the producer's output id. No stage, no path, no type.
    required: true | false
  - id: <artifact-name>       # from outside the pipeline (ADR-055 §3 allowlist)
    source: external
    required: true | false

outputs:
  - id: <artifact-name>       # unique across the resolved flow (ADR-055 §5)
    path: <template-using-${vars}>
    type: <type>
    required: true | false
    primary: true | false

state:
  persisted: [<keys plugins write via core/state>]
  reconstructed: [<keys recomputed at start of run on resume>]
```

### Required hooks per kind

| Kind | Required entry point | Inputs | Output |
|---|---|---|---|
| `agent` | `run` | scope manifest, input artifact, tier | structured artifact (typed) |
| `tool` | `run` | typed args | exit code + structured stdout/stderr |
| `orchestrator` | `run` | upstream artifacts | downstream artifact(s) + verdict |
| `claim-coordinator` | `claim`, `release`, `heartbeat`, `list_claims` | issue id | acquired flag + lease id |
| `daemon` | `tick` | poll interval | events to bus |

All kinds may implement `cleanup` (ADR-056 removed `init` and `finalize`).

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

All lifecycle hooks (`run`/kind-entry, `cleanup`) receive the same two positional arguments from `plugin_hook_call` (see `core/plugin-registry/registry.sh`):

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

For each plugin discovered in a run (ADR-056 — two hooks only):
1. `run` — kind-specific entry; possibly many invocations. State reconstruction on resume is the `run` preamble's responsibility (check `ZBUILD_RESUMING=1`).
2. `cleanup` — released by a `teardown` stage with a `scope` (ADR-054 §7); release locks, write tombstone event. Absent `cleanup` emits `plugin.cleanup.absent` and returns rc=0 — the absence is distinguishable on the event, not on the exit code (#1823, ADR-054 §4).

### Error semantics

> **Superseded by [ADR-054](ADR-054-stage-contract.md) §4; prose replaced 2026-08-11 (#1823).**
> The rc 0/1/2 table below described a `kind: recovery` routing layer that **was never
> implemented** — no recovery plugin has ever been registered — while stages actually
> returned 5, 8, 9, 10, 11 and 143. Leaving the fiction in place is what let the document
> and the engine drift for the life of the project, so it is replaced rather than annotated.

Plugin exit codes are **binary**:
- `0` — my result file is on disk, read it.
- `1` — I failed. Read my result if present; if it is absent I died.

`rc=0` with a missing or unparseable result is a structural failure, not a warning.
Everything a plugin needs to say beyond those two facts belongs in its result file —
`verdict` (its own declared vocabulary), `disposition` (the engine's closed set), and
`reason` (free text, never branched on). See ADR-054 §5 and §6.

The `rc=2 → fatal` and `rc=1 → kind: recovery` **routing rules** are deleted (ADR-054
§10). No recovery plugin has ever been registered and the dispatch path was never
implemented; recoverability is now a declared field (`disposition`), not a number the
engine re-interprets.

**The kind itself is retired (2026-08-20, #1900).** As accepted, this passage kept
`kind: recovery` alive as "the *idea*, not the *routing*" — a keeper awaiting a future
recovery layer. Measurement closed that out: the kind was never merely unbuilt, it was
**superseded**, and by the very field this section points at. `disposition` (ADR-054 §6,
`core/pipeline/disposition.sh`) answers all four action verbs a recovery plugin existed
to return — `retry` → `interrupted`/`throttled`, `escalate` → `exhausted`, `abort` →
`unavailable`/`broken` — and `backtrack` is `route_back` (ADR-045), shipped separately.

More decisively, ADR-054 **inverted the premise**: *"The response table lives HERE, not in
any plugin: no stage decides its own retry policy."* A kind whose entire job was to let a
plugin decide retry policy has nothing left to own. The one keeper that actually declared
`plugin_kind: "recovery"` (#16) was independently closed as `superseded` before this was
noticed.

So `recovery` is removed from `ZBUILD_PLUGIN_KINDS`, its `classify`/`act` hooks are gone,
and the three `recovery.*` names — which never had an emitter, and whose only documented
one (`cq-backtrack`, ADR-013) was never built either — are removed from
`config/event-schema.json`. A future recovery layer builds on `disposition`; it would not
have inherited this vocabulary anyway.

### Fail-closed scanner contract

If a plugin declares `provides.artifact_type` but no artifact exists at `outputs[].path` after `run` completes with exit 0, the engine emits a synthetic blocking finding. Absent evidence IS blocking evidence. (Keepers §C.4.)

### Discovery + lockfile

- `plugins/<kind>/<name>/manifest.yaml` is discovered via filesystem glob at engine startup.
- A discovered set is captured in `~/.zbuild/state/plugins.lock` (manifest hashes + paths) on first successful run.
- Subsequent runs validate against the lockfile; checksum mismatch → warn by default; `strict_plugin_lock: true` config setting → fail.
- `config/plugins.disabled` (line-delimited plugin IDs) excludes plugins per-run.

### Cross-plugin dependencies

A plugin's `requires.plugins` list is enforced at discovery time: the engine refuses to start if a required plugin is missing or disabled. Cyclic dependencies are detected and refused.

### Declared events (amended 2026-08-17 — #1717)

A plugin declares the events it emits in its own manifest, under `provides.events`:

```yaml
provides:
  role: shape_floor
  events:
    - shape_floor.pass
    - shape_floor.fail
```

The engine composes the known-type set at load from `config/event-schema.json` **plus** every discovered
manifest's `provides.events` (`core/event-bus/known-types.sh`). Before this, `config/event-schema.json`
enumerated all 269 event names — about half of them plugins' — so a plugin could not register an event
without editing a file in the engine's `config/` directory. That file is a shape-change path
(`config/shape-change-paths.txt`), so plugin work that touched it was pushed into shape-change mode and
the shape floor then demanded golden updates the plan had not scoped. On run `20260803093634-57718`
(PR #1697) the build's only in-scope option was to **un-register the event it had just added** — which is
how `acceptance.gate.wiring_not_on_path` came to be emitted but unknown. Adding an event now touches
exactly one file, and it is always a file already in scope for the plugin being worked on.

**Ownership rule.** Ownership is by *namespace*, with one exception:

- **Engine** (`config/event-schema.json`): `pipeline.*`, `stage.*`, `stage_io.*`, `plugin.*`, `cycle.*`,
  `router.*`, `loop.*`, `state.*`, `registry.*`, `parallel.*`, `redaction.*`, `template.*`, `strategy.*`,
  `artifact.*`, `model.*`, `cost.*`, plus the engine's contract layers —
  `orch.*` (`core/orch/contract.sh`), `memory.*` (`core/memory/contract.sh`),
  `backend.*` (`core/config/config.sh`), `detection.*` (`core/detect`), `llm.*` (`scripts/lib/llm-agent.sh`),
  `selfhost.*`. These are named by the *contract*, not by whichever backend plugin is bound to it: the
  event means the same thing whichever `orch-*`/`memory-*` plugin is selected, so it cannot live in one
  of them.
- **Plugin** (its `provides.events`): every other namespace, resolved to the plugin that emits it —
  `review.*` → `review-aggregator`, `test_assessment.*` → `test`, `claim.*` → the claim-coordinator
  plugin, `validate.health_check.*` → `health-check` (not `validate` — the *emitter* decides when a
  namespace spans plugins), `deploy.release.*` → `deploy-release`, `release.*` → `deploy-release`.
- **Exception:** `plugin.pr_open.*` is engine-namespaced but names a single plugin, so it belongs to
  `pr-open`.

A plugin MAY emit an engine event (`plugin.run.complete`, `loop.git_diff_failed`) without declaring it —
those are the engine's contract, declared centrally. It may NOT emit an event in its own namespace
without declaring it; `tests/unit/event-schema-emitted-coverage-test.sh` [SPEC-1717-1] fails the build.

**Cost.** `_eb_known_type` used to fork one `jq` **per emit**; composing from N manifests per emit would
have multiplied that by plugin count. Composition happens once per process into an associative array,
and once per **run** into `${ZBUILD_EVENTS_DIR}/known-event-types.cache` (keyed by schema path +
plugins root, replaced atomically), so the steady-state check forks nothing at all. Pinned by
`tests/unit/event-schema-manifest-composition-test.sh` [SPEC-4]/[SPEC-5].

**Seams.** `ZBUILD_EVENT_SCHEMA` still substitutes the engine leg (~240 tests set it); `ZBUILD_PLUGINS_ROOT`
substitutes the manifest leg. Severity is unchanged — schema-as-warn: an unknown type is logged and
never blocks.

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
- Plugin **bootstrap/teardown** lifecycle (`zbuild bootstrap` / `zbuild teardown` commands and their interaction with the plugin `cleanup` hook at CI boundary) is deferred to Phase 1.  See [PHASE-DEFERRALS.md](PHASE-DEFERRALS.md) and ADR-010 §Implementation Notes.

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
