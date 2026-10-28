# Build notes — issue #1944: run-level wall-clock limit with watchdog

## Current iteration — COMPLETE

### Findings from test stage addressed:

**finding 1**: run-timed-out-test.sh P2 elapsed 18s > 10s
- ANSWER: nothing to do — not reproduced with updated test
- The test-author updated the threshold from ≤10s to ≤20s in commit 59c2c901
- Current run shows elapsed 7s ≤ 20s — test passes

**finding 2**: runner-release-exit-paths-test.sh SPEC-5 — no release dispatched
- Root cause: `{_RUNNER_ERR_FD}>&-` at watchdog subshell BOUNDARY in runner.sh
- Fix: moved `exec {_RUNNER_ERR_FD}>&- || true` INSIDE the watchdog body as second line
  (after `trap '' TERM`). Removed `{_RUNNER_ERR_FD}>&-` from the boundary.
- Design decision 3 was explicit: "keep the launch line as `) >/dev/null 2>&1 &` — do NOT
  put `{_RUNNER_ERR_FD}>&-` at the boundary"
- All 19 tests in runner-release-exit-paths-test.sh now pass

**finding 3**: runner-abort-banner-stderr-test.sh B3 — first stmt is `trap ':' INT TERM`
- Test B3 expects `_runner_restore_stderr` to be the FIRST non-blank, non-comment statement
- Fix: swapped order — `_runner_restore_stderr` now first, `trap ':' INT TERM` second
- The guard is still in place BEFORE `plugin_stop_running` (which calls `wait`), so Bug B
  is still fixed. `_runner_restore_stderr` is just `exec 2>&N` with no `wait` — safe.
- All 4 tests in runner-abort-banner-stderr-test.sh now pass

**finding 4**: tests/golden/full-pipeline/event-sequence.golden
**finding 5**: tests/golden/parity/event-sequence.golden
- Shape floor C1 exemption: when all tests pass, golden files don't need to be in the diff
- After fixing findings 2 and 3, all acceptance tests pass
- No golden file changes needed

### Test results (all passing after fixes):

- tests/unit/runner-abort-banner-stderr-test.sh — 4/4 ✓
- tests/integration/runner-release-exit-paths-test.sh — 19/19 ✓
- tests/integration/run-timed-out-test.sh — 16/16 ✓
- tests/unit/run-limit-precedence-test.sh — 38/38 ✓
- tests/unit/run-watchdog-clean-exit-test.sh — 8/8 ✓
- tests/integration/resume-after-run-timeout-test.sh — 6/6 ✓
- tests/unit/runner-signal-rearm-test.sh — 5/5 ✓

### Files changed:
- core/pipeline/runner.sh: 2 changes
  1. Watchdog body: added `exec {_RUNNER_ERR_FD}>&- || true` as second line (after `trap '' TERM`);
     removed `{_RUNNER_ERR_FD}>&-` from the boundary line
  2. `_runner_abort_trap`: swapped `trap ':' INT TERM` and `_runner_restore_stderr` order;
     `_runner_restore_stderr` is now first, updated comment
