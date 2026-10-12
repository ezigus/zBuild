# Build Checkpoint — Issue 1801

## Files Read So Far
- lifecycle.sh: plugin_hook_call has no watchdog yet; need to add per-dispatch timer for run hook using zbuild_pg_kill
- runner.sh (_runner_dispatch_always_run): Uses _TPL_STAGE_ROUTER_TIMEOUT_* and hand-rolled kill -TERM/-KILL; must switch to _TPL_STAGE_TIMEOUT_S_* and zbuild_pg_kill
- contract.sh: Has orch-sequential fallbacks in orch_load_backend; must be removed; _orch_load_backend defaults to "sequential" — must change to "bash-parallel"
- All 9 acceptance tests: read and understood

## What Needs To Be Done
1. scripts/lib/proc-group.sh — check if zbuild_pg_kill exists; add if not
2. core/pipeline/template.sh — add stage_timeout_s parsing (_TPL_STAGE_TIMEOUT_S_<id>), validation
3. core/plugin-registry/lifecycle.sh — add per-dispatch watchdog in plugin_hook_call for run hook
4. core/pipeline/runner.sh — update _runner_dispatch_always_run: _TPL_STAGE_TIMEOUT_S_* + zbuild_pg_kill
5. core/orch/contract.sh — remove orch-sequential fallbacks; default to bash-parallel; add misconfigured errors
6. core/orch/local_engine.sh — replace _orch_local_kill_slot with zbuild_pg_kill
7. core/pipeline/strategies/fanout.sh, sequential.sh, map.sh — remove ZBUILD_ORCH_TIMEOUT
8. config/templates/simple.yaml — add stage_timeout_s to all stages
9. Delete plugins/tool/orch-sequential/ dir and related files
10. Update test files (summary-mandatory, dispatch-rc-guard, etc.) to use orch-mock instead of orch-sequential
11. Update ADR files with Enforced by sections
12. Remove ADR-054, ADR-017, ADR-011 from adr-enforcement-baseline.txt

## Still Need to Read
- proc-group.sh (does zbuild_pg_kill exist?)
- template.sh (current AWK parser)
- local_engine.sh (_orch_local_kill_slot pattern)
- simple.yaml (current state)
- ADR-054, ADR-017, ADR-011 (for Enforced by sections)
- The tests that need migration (summary-mandatory-test.sh, etc.)

## Next If Stopped
Read proc-group.sh and template.sh first, then implement in order listed above.
