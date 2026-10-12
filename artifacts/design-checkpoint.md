# Design Checkpoint — Issue #1801

## Files read so far
- plan.json, requirements.json
- core/plugin-registry/lifecycle.sh (full)
- core/pipeline/runner.sh:1-1231 (rendered banner, always_run at 2380-2469)
- core/pipeline/strategies/fanout.sh (full)
- core/pipeline/strategies/sequential.sh (full)
- core/pipeline/strategies/map.sh:1-80 (ZBUILD_ORCH_TIMEOUT at line 300)
- core/orch/contract.sh (full - has orch-sequential fallback)
- core/orch/local_engine.sh (full - _orch_local_collect_results, _orch_local_shutdown_pool)
- core/pipeline/template.sh (partial - timeout parsing, _tpl_parse_always_run)
- core/pipeline/disposition.sh (timed_out in disposition set, line 64)
- core/pipeline/verdict.sh (partial)
- scripts/lib/proc-group.sh (zbuild_pg_kill at line 146)

## Key findings
1. ZBUILD_ORCH_TIMEOUT:-300 in fanout.sh:79, sequential.sh:62, map.sh:300 → remove all
2. _runner_dispatch_always_run reads _TPL_STAGE_ROUTER_TIMEOUT_ (runner.sh:2426) → change to stage_timeout_s
3. _orch_local_collect_results uses _orch_local_kill_slot TERM, sleep 0.5, KILL (0.5s grace)
4. _orch_local_shutdown_pool uses _orch_local_kill_slot with 0.5s grace too
5. orch_load_backend has fallback to orch-sequential (contract.sh:165-182) → remove
6. _orch_load_backend defaults to "sequential" (contract.sh:203) → change to bash-parallel
7. timed_out is already in the disposition set (disposition.sh:64)
8. _TPL_STAGE_ROUTER_TIMEOUT_ for always_run stages stored in template.sh:679
9. Tests using orch-sequential: summary-mandatory, dispatch-rc-guard, stdin-spawn-guard, core-orch-run-id-isolation, plugin-artifact-goldens, adr059-no-tmpdir-defaults
10. runner-release-exit-paths-test.sh SPEC-5 (line 299) and SPEC-6 (line 347) pin router.timeout_s for always_run → superseded
11. exit-path-teardown-budget-guard-test.sh SPEC-1 checks ZBUILD_RELEASE_TIMEOUT in SPEC-5 → superseded

## Additional scope beyond seed
- tests/integration/runner-release-exit-paths-test.sh (SPEC-5/6 use router.timeout_s for always_run)
- tests/unit/exit-path-teardown-budget-guard-test.sh (SPEC-1 pins ZBUILD_RELEASE_TIMEOUT)
- docs/adr/ADR-035-orchestrator-run-state-isolation.md (references orch-sequential)
- docs/wiki/plugins/orch-sequential.md (to be deleted)
- plugins/tool/orch-sequential/ (to be deleted, includes tests/)
- plugins/tool/orch-sequential/tests/orch-sequential-test.sh (to be deleted)

## Complete
Writing design.md now
