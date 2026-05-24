# ADR-001: Plugin Contract

**Status:** Accepted
**Date:** 2026-05-24

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
version: <semver>
description: |
  <one paragraph>

hooks:
  init: <function-name>           # called once per pipeline run, before any run
  run: <function-name>            # called by orchestrator (or kind-specific)
  finalize: <function-name>       # called after all cycles complete
  cleanup: <function-name>        # called on abnormal exit (kill, abort)

requires:
  core: [redaction, event-bus, state, locks, github, ...]
  plugins: [<plugin-id>, ...]

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

## References

- [KEEPERS.md](../KEEPERS.md) §A (stage dispatch), §F (personas as agent plugins).
- [ARCHITECTURE.md](../ARCHITECTURE.md) §2 (plugin contract), §3 (data flow).
- `legacy/scripts/lib/skill-registry.sh` — the only plugin-shaped surface in the upstream today; informs the manifest design but is narrower (prompt fragments only).
