# Test author notes — Issue #1801

## Summary of work
Round 5 — fixed three gaps identified by the round-2/3 checker. All SPECs complete.

## Round 5 fixes

### Gap 1: SPEC-1 map strategy (orch-timeout-applies-test.sh)
Added `source map.sh` after fanout/sequential sources at line ~53.
Added runtime spy section between SPEC-1d and SPEC-1e (inserted at ~line 204):
- Calls `_strategy_run_map "pool-map-spec1" "testjob" "testworker" ...`
- The capturing spy (orch_collect defined at line 81) records _SPEC1_OC_TIMEOUT
- Asserts _SPEC1_OC_TIMEOUT == _spec1_expected_timeout (template's timeout_s: value)
- Also verifies ZBUILD_ORCH_TIMEOUT=300 is ignored (spy still gets template value)
Old code: spy captures 300 (ZBUILD_ORCH_TIMEOUT:-300) → FAIL
New code: spy captures template timeout_s: value → PASS

### Gap 2: SPEC-5 router.timeout_s (runner-release-exit-paths-test.sh)
Added after the existing ZBUILD_RELEASE_TIMEOUT check (lines 495-506):
  `if ! grep -q '_TPL_STAGE_ROUTER_TIMEOUT' "$RUNNER"; then assert_pass ... else assert_fail`
Old code has `local _ar_to_var="_TPL_STAGE_ROUTER_TIMEOUT_${_ar_safe}"` at runner.sh:2463 → FAIL
New code removes it → PASS

### Gap 3: SPEC-6 runtime behavioral (orch-kill-uses-pg-kill-guard-test.sh)
Added before print_test_results (lines 84-156):
- Sources local_engine.sh and proc-group.sh
- Starts a wrapper as new process group (set -m)
- Wrapper forks a child with trap '' TERM (ignores TERM), records child PID to file
- No .inner_pid file → _orch_local_kill_slot only gets wrapper_pid
- Calls _orch_local_collect_results with 2s timeout
- After collect returns, polls whether child is still alive
Old code: direct kill -KILL wrapper_pid → child is orphaned, still alive → FAIL
New code: zbuild_pg_kill sends to whole group → child gets KILL → PASS

## Round 4 work (still in place)

## Final status: COMPLETE

All 12 SPECs and all existing checks have assertions written/updated to disk.

## What was done in round 4

### Existing checks — exit-path-teardown-budget-guard-test.sh

**[SPEC-1]**: Updated to grep for `_SPEC5_STAGE_TIMEOUT` (not `ZBUILD_RELEASE_TIMEOUT`).
The intent-comment was updated: `_SPEC5_STAGE_TIMEOUT` is the new pin (template `timeout_s:`
for release), replacing `ZBUILD_RELEASE_TIMEOUT` which the engine no longer reads after #1801.

**[SPEC-3]**: Updated to grep for `_SPEC5_STAGE_TIMEOUT=[0-9]+` (not `_SPEC5_RELEASE_TIMEOUT=[0-9]+`).
Also updated the variable assignment to `_SPEC5_STAGE_TIMEOUT="$_pinned"` so the arithmetic
evaluation `$(( _expr ))` can expand the variable by name when evaluating `_SPEC5_STAGE_TIMEOUT * 3 + 6`.

### Existing check — plugin-artifact-goldens-test.sh [G5]

Removed the entire G5 block (the section from the `# ─── G5:` comment through the final
`g5_golden_rc` assertion) that verified orch-sequential's golden. The header section says
"5 plugin artifact outputs" but after G5 removal only G1-G4 remain. The file ends at
`print_test_results` + `exit $((FAIL > 0))`.

### SPEC-11 — orch-mock pool isolation [#1801/SPEC-11]

Added M5 assertion to `plugins/tool/orch-mock/tests/orch-mock-test.sh`:
- Spawns two independent pools (m5-pool-pass, m5-pool-fail)
- Dispatches only passing work units to pool_pass, only failing units to pool_fail
- Collects from each pool independently
- Asserts pool_pass collect returns 0 (not contaminated by failing pool)
- Asserts pool_fail collect returns 1 (not contaminated by passing pool)
- Fails on any implementation that uses a shared queue

### SPEC-12 — test file updates for orch-sequential retirement [#1801/SPEC-12]

**(a) adr059-no-tmpdir-defaults-test.sh**:
- Removed SPEC-4 block (tested `_orch_seq_pool_dir p1` from orch-sequential plugin)
- SPEC-8 loop changed: removed orch-sequential from iteration; removed `_orch_seq_pool_dir` case
- SPEC-3 (bash-parallel) and SPEC-6 (ruflo-hive) preserved

**(b) core-orch-run-id-isolation-test.sh**:
- Removed P4 (source orch-sequential/plugin.sh + _orch_seq_pool_dir run-AAA assertion)
- Removed P5 (sequential ZBUILD_POOL_ROOT override assertion)
- P1–P3 (bash-parallel) run isolation preserved

**(c) dispatch-rc-guard-test.sh**:
- Removed `plugins/tool/orch-sequential/plugin.sh|0` from `_PINNED`

**(d) stdin-spawn-guard-test.sh**:
- Removed two orch-sequential stdin-close pins (file work units + inline work units)

**(e) summary-mandatory-test.sh**:
- Changed SPEC-3 loop from `for _svc in cache-local memory-sqlite orch-sequential` to
  `for _svc in cache-local memory-sqlite`

## What was done in previous rounds (verified still present)

### tests/integration/orch-timeout-applies-test.sh [SPEC-1]
- SPEC-1a/b: fanout + sequential spy: orch_collect receives template_stage_time_limit (not 300)
- SPEC-1c/d: static grep: map/fanout/sequential have no ZBUILD_ORCH_TIMEOUT reference
- SPEC-1e: runtime: _ORCH_COLLECT_OUTCOME=timed_out on planted hang (local_engine)
- SPEC-1f: runtime: strategy propagates timed_out; stderr names stage and limit

### tests/integration/orch-backend-misconfigured-test.sh [SPEC-2, SPEC-4, SPEC-10]
- SPEC-2: "sequential" returns non-zero, backend not loaded, names "sequential", "misconfigured"
- SPEC-4: absent backend returns non-zero, names "orch-absent-spec4", "misconfigured"
- SPEC-10: unreadable plugin.sh returns non-zero, names "orch-broken-spec10", "misconfigured"

### tests/unit/orch-sequential-absent-guard-test.sh [SPEC-3]
- Plugin directory does not exist
- No code/config file outside docs/adr/ names "orch-sequential"

### tests/integration/runner-release-exit-paths-test.sh [SPEC-5]
- Runtime: blocking hook under template with timeout_s: 5 exits in < 20s (not ~30s)
- Static: ZBUILD_RELEASE_TIMEOUT not present in runner.sh

### tests/unit/orch-kill-uses-pg-kill-guard-test.sh [SPEC-6]
- Static: _orch_local_kill_slot calls zbuild_pg_kill
- Static: always-run watchdog in runner.sh calls zbuild_pg_kill
- Static: zbuild_pg_kill defined in proc-group.sh; local_engine.sh sources it

### docs/adr/ADR-011-pluggable-backends.md + ADR-017-per-stage-router-config.md [SPEC-7]
- Both have ## Enforced by sections naming the relevant tests
