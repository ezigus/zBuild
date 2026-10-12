# Plan checkpoint — issue #1801 (stage timeouts)

## Files read and key findings

- `core/plugin-registry/lifecycle.sh` (`plugin_hook_call`): no process group, no timer on `run` hook. `#2024` comment notes pgid not written at dispatch seam. Decisions 1+2 require: `set -m` on plugin subshell, watchdog using `zbuild_pg_kill`, write `timed_out` on expiry.
- `core/orch/contract.sh`: `orch_load_backend` has two sequential fallbacks; `_orch_load_backend` defaults to "sequential". Both must become hard `misconfigured` errors.
- Strategies `map.sh`:300, `sequential.sh`:62, `fanout.sh`:79: all pass `ZBUILD_ORCH_TIMEOUT:=300` to `orch_collect`. Must be removed.
- `runner.sh` `_runner_dispatch_always_run`: hand-rolled TERM/KILL, reads `_TPL_STAGE_ROUTER_TIMEOUT_*`. Must use `zbuild_pg_kill` and read `_TPL_STAGE_TIMEOUT_S_*`.
- `core/orch/local_engine.sh` `_orch_local_collect_results`: `_orch_local_kill_slot TERM/KILL` (0.5s, single PID). Must use `zbuild_pg_kill`.
- `core/pipeline/template.sh`: parses `router.timeout_s` into `_TPL_STAGE_ROUTER_TIMEOUT_<safe>`. Needs parallel `stage_timeout_s` → `_TPL_STAGE_TIMEOUT_S_<safe>`, validation, getter.
- `config/templates/simple.yaml`: no `stage_timeout_s` anywhere. Always-run stages use `router.timeout_s`.
- `plugins/tool/orch-sequential/`: 3 files (manifest.yaml, plugin.sh, tests/orch-sequential-test.sh). Delete.
- `tests/golden/orch-sequential-capabilities.golden`: Delete.
- `docs/wiki/plugins/orch-sequential.md` + `docs/wiki/Plugins.md` (reference): Delete/update (guard test would flag them).
- ADR-011 and ADR-017 are in `config/adr-enforcement-baseline.txt` (no Enforced by section yet). New statements need Enforced by in same PR; they also get removed from baseline.
- ADR-054 is NOT in baseline (already has sections). New §9 additions need inline Enforced by entries.
- Tests using orch-sequential as fixture: summary-mandatory-test.sh, dispatch-rc-guard-test.sh, stdin-spawn-guard-test.sh, core-orch-run-id-isolation-test.sh, adr059-no-tmpdir-defaults-test.sh, plugin-artifact-goldens-test.sh.

## Conclusions

Complete. Plan ready to emit.
