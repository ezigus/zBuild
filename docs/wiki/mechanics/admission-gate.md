# admission-gate

The admission gate is a set of fail-closed preconditions that zBuild evaluates before a pipeline run begins. If any required input, tool, or configuration is missing or malformed, the run is refused immediately with a clear error rather than proceeding into a half-started state.

## How to use

The admission gate runs automatically every time you invoke `runner.sh`. There is no separate command. When the gate rejects a run, the output names the failing precondition so you can fix it and retry.

```bash
# Standard invocation — the gate runs before the first stage:
zbuild run --issue 42

# Dry-run still triggers the gate:
zbuild run --issue 42 --dry-run
```

If the gate passes, the pipeline proceeds to stage dispatch. If it fails, the run exits with a non-zero code and no stages are touched.

## Reference

**Defined in:** `core/pipeline/runner.sh`

**Key behaviors:**

| Behavior | Detail |
|---|---|
| Fail-closed | A failed precondition exits immediately; no stage is started, no state is written. |
| Required tooling | Validates that platform-detected dependencies are present before dispatch. |
| Run inputs | Confirms `--issue` or `--goal` is supplied and well-formed. |
| Template resolution | Verifies the requested template resolves and all leaf stages map to known plugins (see `_runner_validate_leaf_resolvability`). |
| Memory backend | `memory_init` must succeed; failure exits with rc=2 before any gate logic runs. |
| Clear messaging | Failures emit a human-readable explanation to stderr — no silent degrades. |

The gate does not write pipeline state. If it rejects the run, no `runs/<run_id>/` directory is created.

## Advanced

_Newcomers can skip this section._

**Plugin membership enforcement (ADR-047 §5):** `_runner_validate_leaf_resolvability` is the sole load-time membership fence. Every leaf stage in the resolved template flow must resolve to a plugin via `resolve_stage_plugin` (role-then-id, ADR-042). In `enforce` mode (the default for real runs), an unresolved leaf fails closed at rc=2. In `warn` or `off` mode (used by mock-roster test suites), the gate is a no-op and dispatch-time resolution acts as the backstop. The two modes must agree — never set `ZBUILD_CONTRACT_VALIDATOR` to `warn` in production.

**Scope allowlist initialization (ADR-043):** `_runner_export_scope_allowlist` is called per-stage after the gate passes, not during the gate itself. Before `plan.json` exists the allowlist is empty — this is safe because the scope manifest is the base allowlist and per-stage values are strictly additive.

**Vision document gate (Phase 1.1, issues #1358/#1360):** a future gate precondition will require a conforming vision document — fail-closed if missing, malformed, or over the ~300-word cap. `zbuild vision init` will scaffold one. Not yet enforced.

**ADR references:** ADR-001 (plugin contract), ADR-009 (platform-aware modularity), ADR-042 (role-then-id resolution), ADR-043 (scope allowlist), ADR-047 (manifest membership fence).

_See also: [[mechanics/scope-governance]], [[mechanics/state-and-resume]], [[Troubleshooting]]._
