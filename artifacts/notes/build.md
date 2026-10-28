# Build notes — issue #1944: run-level wall-clock limit with watchdog

## Final Status (iteration 7 — COMPLETE)

### All fixes committed

**Bug A** (3 integration test timeouts — orphaned sleep holds pipe write end):
- Committed in 9a853724: `{_RUNNER_ERR_FD}>&-` closes the high-numbered fd in watchdog subshell
- COMPLETE ✓

**Bug B** (double-SIGTERM aborts EXIT trap → always_run never runs):
- Initially committed in 741c8466, but guard was placed AFTER `plugin_stop_running`
- Fixed in 772cef6f: moved `trap ':' INT TERM` to FIRST line of `_runner_abort_trap` (before `_runner_restore_stderr` and `plugin_stop_running`)
- COMPLETE ✓

**Bug C** (SPEC-5 in runner-signal-rearm-test.sh — awk matches wrong line):
- Committed in 9a853724: runner-signal-rearm-test.sh awk pattern fixed to `/trap '.*' TERM$/`
- COMPLETE ✓

### Test results (all passing)

- tests/integration/runner-release-exit-paths-test.sh — 19/19 ✓
- tests/unit/run-limit-precedence-test.sh (SPEC-2/5/6) — 38/38 ✓
- tests/unit/run-watchdog-clean-exit-test.sh (SPEC-3) — 8/8 ✓
- tests/integration/resume-after-run-timeout-test.sh (SPEC-4) — 6/6 ✓
- tests/integration/run-timed-out-test.sh (SPEC-1) — 16/16 ✓
- tests/unit/runner-signal-rearm-test.sh — 5/5 ✓
- tests/unit/runner-pipeline-end-test.sh — 38/38 ✓
- tests/unit/run-open-items-test.sh — 53/53 ✓
- tests/unit/abort-propagation-test.sh — 18/18 ✓
- tests/unit/shape-floor-test.sh — 24/24 ✓
- tests/unit/shape-floor-content-stable-test.sh — 7/7 ✓

### Findings addressed

**test finding 1**: runner-release-exit-paths-test.sh SPEC-5 — RESOLVED (test now passes)

**test finding 2/3**: event-sequence.golden files — NOTHING TO DO. When the full test suite
passes, `_sf_floor_verified` returns 0 for event-sequence.golden files (via _SF_VERIFY_OK=1,
_SF_FAILED_COUNT=0), so the shape floor does not require them in the diff. No content test
asserts these files for this issue's acceptance criteria.

**issue-acceptance finding 1 (R-10)**: RESOLVED — test suite passes.
**issue-acceptance finding 2 (R-4)**: RESOLVED — P4 in run-timed-out-test.sh tests both
release and persist (both pass). The SPEC-5 regression is now fixed.
**issue-acceptance finding 3/4 (R-9/ADR-054 §9)**: NOTHING TO DO — SPEC-6 passes, ADR-054
§11 exists with Enforced by section. The issue draft said "§9 amended" but §11 was correctly
added. This is a stale label in the issue text per the design.

### Working tree state

Clean — no uncommitted changes. All fixes are in commits 772cef6f and earlier.
