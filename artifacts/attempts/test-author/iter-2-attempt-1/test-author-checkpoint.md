# Test Author Checkpoint — Issue #1801 (Iteration 1/run 2) — COMPLETE

## Status: ALL SPEC-CORRESPONDENCE FINDINGS ADDRESSED

## Changes made this run:

### 1. stage-timeout-dispatch-test.sh (SPEC-1 partial → complete)
- Added assertion after "watchdog writes disposition timed_out" section
- Checks that the plugin.run.timed_out event in lifecycle.sh carries stage= and timeout_s= fields
- grep -A4 on lifecycle.sh around 'plugin\.run\.timed_out'; checks stage= AND timeout_s= appear
- FAILS on pre-change code (no plugin.run.timed_out in lifecycle.sh), PASSES after

### 2. stage-timeout-always-run-test.sh (SPEC-10 wrong pattern → fixed)
- Changed pattern from `kill -TERM -- -"$_ar_pid"` to `kill -(TERM|KILL) -- -"$_ar_pid"`
- The actual code has `kill -KILL -- -"$_ar_pid"` (line 2468 runner.sh), not TERM
- Now correctly catches the hand-rolled hook kill
- FAILS on current implementation (kill -KILL still there), PASSES after fix

### 3. stage-timeout-precedence-test.sh (SPEC-3 tier 2/3 improved)
- Tier 2: Added source check that plugin_hook_call body references ZBUILD_STAGE_TIMEOUT_S
- Tier 3: Added specific check for `_lc_hook_to=5400|ZBUILD_STAGE_TIMEOUT_S:-5400` in plugin_hook_call body
- Both fail on pre-change code (no watchdog in plugin_hook_call), pass after

### 4. stage-timeout-no-flat-limit-test.sh (SPEC-7 behavioral check added)
- Added check that orch_collect/orch_wait calls in strategy files have no --timeout flag
- Complements the ZBUILD_ORCH_TIMEOUT absence check
- FAILS on pre-change code if --timeout was passed as `--timeout "$ZBUILD_ORCH_TIMEOUT"`, PASSES after

### 5. orch-backend-misconfigured-test.sh (SPEC-9 unreadable case added)
- Added test section: creates manifest.yaml with chmod 000 → backend treated as "not found" → misconfigured
- Verifies orch_load_backend returns non-zero for unreadable config
- FAILS on pre-change code (silent fallback), PASSES after

### 6. runner-release-exit-paths-test.sh (SPEC-2 external-SIGTERM path added)
- Added BUILD_RUN_SPAWN_IGNORE_TERM support to build_run fixture
- Added SPEC-2ext test section: sends TERM to runner while build spawns child ignoring TERM
- Verifies child doesn't survive — external SIGTERM path kills run hook's process group
- Tagged [#1801/SPEC-2]

## SPEC-10 test is CORRECT (not changed)
The test in stage-timeout-dispatch-test.sh correctly finds `kill -KILL -- -"$_lc_hook_pid"`
in lifecycle.sh line 517. The test will fail until the implementation replaces this with
zbuild_pg_kill (a build stage task, not test-author).

## All prior iteration existing-checks verified:
- template-always-run-test.sh: _TPL_STAGE_TIMEOUT_S_release ✓
- runner-release-exit-paths-test.sh SPEC-5/6: ZBUILD_STAGE_TIMEOUT_S ✓
- exit-path-teardown-budget-guard-test.sh: ZBUILD_STAGE_TIMEOUT_S ✓
- plugin-artifact-goldens-test.sh G5: removed ✓
- dispatch-rc-guard-test.sh: orch-mock ✓
- adr059-no-tmpdir-defaults-test.sh: orch-sequential removed ✓
- stdin-spawn-guard-test.sh: orch-mock ✓
- core-orch-run-id-isolation-test.sh: orch-mock ✓
- summary-mandatory-test.sh: orch-sequential removed ✓
- design-prompt-scope-charter-test.sh T6: stage_timeout_s: 3900 ✓
- orch-sequential-retired-guard-test.sh: orch-backend-misconfigured excluded ✓
- event-schema-emitted-coverage-test.sh SPEC-18: both types checked ✓
