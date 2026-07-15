# admission-gate

The admission gate is a checklist that runs before the pipeline starts. If anything required is missing or misconfigured, zBuild refuses to begin rather than failing partway through with a confusing error.

## How to use

The admission gate runs automatically at the start of every `runner.sh` invocation. There is nothing to configure to enable it — it is always active. If a precondition fails, the run exits with a clear diagnostic message and a non-zero exit code before any stage executes.

To surface which precondition failed, read the error printed to stderr. Common triggers:

- A required flag (`--issue` or `--goal`) is missing.
- The memory backend fails to initialise.
- A template stage names a plugin that cannot be resolved to a real plugin directory.

## Reference

**Defined in:** `core/pipeline/runner.sh`

**What it checks:**

| Precondition | Outcome on failure |
|---|---|
| `--issue` or `--goal` flag present | Exit rc=1, usage printed |
| Memory backend initialises (`memory_init`) | Exit rc=2 |
| Every template leaf resolves to a plugin via `resolve_stage_plugin` (role-then-id, ADR-042) | Exit rc=2 with unresolved leaf name |
| Issue state collision guard (locked state, different run_id, in-progress within 24 h) | Exit rc=3 |

**Enforcement mode:** The leaf-resolvability check honours `ZBUILD_CONTRACT_VALIDATOR`. When set to `enforce` (the default), an unresolved leaf is a hard failure. When set to `warn` or `off`, the check is skipped and dispatch-time resolution acts as the backstop.

**Fail-closed:** A failed precondition always stops the run. There is no silent degradation.

## Advanced

_Newcomers can skip this section._

The admission gate is not a plugin and does not emit events — it is purely a pre-dispatch guard inside `runner.sh`. Its two distinct enforcement paths map to separate ADRs:

- **Leaf resolvability** (`_runner_validate_leaf_resolvability`) — ADR-047 §5. This replaced the old hardcoded-roster fence. It shares the same `ZBUILD_CONTRACT_VALIDATOR` mode as the inter-stage contract validator (ADR-020) so both fences agree on whether enforcement is on or off in a given run. Mock-roster test suites drive `runner.sh` under `warn` mode precisely to avoid this gate (the dispatch-time backstop still fires for genuinely missing plugins mid-run).

- **Locked state collision guard** — ADR spec SPEC-G. `locked_state_update` refuses to overwrite a different live run (`run_id ≠` + `in_progress` + `updated_at < 24 h`), returning rc=3. This prevents two concurrent pipeline runs from corrupting shared state.

Phase 1.1 (issues #1358/#1360) will extend the admission gate to require a conforming vision document — fail-closed if absent, malformed, or over the ~300-word cap — with `zbuild vision init` to scaffold one.

See also: [[mechanics/scope-governance]], [[mechanics/state-and-resume]], [[Troubleshooting]]
