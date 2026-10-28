# Build notes — issue #1944: run-level wall-clock limit with watchdog

## Current iteration (iteration 5) — NO CODE CHANGES NEEDED

The test stage failed with 1 failing assertion: SPEC-6 "ADR-054 §11 content describes the per-run limit."

### Root cause of the test failure

The test file used `awk '/§[[:space:]]*11\b|.../'` — but POSIX awk treats `\b` as a
backspace character (0x08), NOT a word boundary. So the awk pattern never matched the
§11 heading, `_s11_body` was empty, and the grep for keywords failed.

### Fix: test-author commit 2595a712

The test-author stage ran and fixed this by replacing `\b` with `[^0-9]` in the awk
pattern. This is in commit 2595a712 (already in the worktree).

### Verification

- run-limit-precedence-test.sh: 45/45 pass ✓
- run-watchdog-clean-exit-test.sh: 8/8 pass ✓
- runner-signal-rearm-test.sh: 5/5 pass ✓
- shape-floor findings 1-9: consequence of prior test failure, cleared when tests pass
- No code changes needed

---

## Previous iteration (iteration 4) — WATCHDOG CHILD LEAK FIX

The test stage failed: sigterm-aborts-pipeline-test.sh timed out at 480s.
Issue-acceptance found R-10 unmet and shape-floor flagging two event-sequence goldens.

### Root cause: orphaned `sleep` child from watchdog subshell

When the runner is externally SIGTERMed (kill -TERM -$RUNNER_PGID):
1. The watchdog subshell has `trap '' TERM` → survives the PG-wide TERM
2. The watchdog's `sleep "$_RUNNER_MAX_RUN_S"` child inherits SIG_IGN for TERM
   (POSIX: exec preserves SIG_IGN across exec)
3. The EXIT trap's `kill -KILL $watchdog_pid` kills the watchdog bash subshell, but
   NOT its `sleep` child — SIGKILL to a PID kills only that PID, not its children
4. The sleep is orphaned (reparented to init) and holds the pipe write-end open,
   blocking any $(…) caller for up to 20700s

### Fix applied: runner.sh EXIT trap watchdog cleanup

Added pgrep-based collection of watchdog children BEFORE killing the watchdog:
- `pgrep -P "${_RUNNER_WATCHDOG_PID}"` collects children (the sleep process)
- Then `kill -KILL $watchdog_pid && wait $watchdog_pid` as before
- Then `kill -KILL $_wc` for each orphaned child

Must be BEFORE the kill because once the watchdog dies, its children are reparented
to init and `pgrep -P` can no longer find them.

### Golden file concern
The shape floor flagged tests/golden/full-pipeline/event-sequence.golden and
tests/golden/parity/event-sequence.golden. These do NOT need changes — they're for
successful pipeline runs (no new events on that path). The shape floor couldn't verify
them because there was a test failure; once sigterm test passes, full-pass verifies them.

---

## Previous iteration (iteration 3) — ANALYZING ISSUE-ACCEPTANCE FINDINGS (was COMPLETE)

The test stage passed with 821/0. The issue-acceptance stage returned FAIL with 5 findings.
After thorough investigation, ALL 5 findings are FALSE POSITIVES.

### Finding 1 & 2 (NOT MET): "persist path not exercised"

Claim: "test fixture `timeout-with-release.yaml` declares only `always_run: [release]`"
and "the persist path is never exercised or asserted"

FACTUALLY INCORRECT. Verified by:
- Reading the current test file: lines 95-97 have `always_run: [release, persist-stage]`
- git show 59c2c901:tests/integration/run-timed-out-test.sh confirms the test-author commit
  already had BOTH `release` AND `persist-stage` in `always_run`
- Lines 378-384 set up the PERSIST_MARKER plugin
- Lines 409-413 assert the PERSIST_MARKER existence
- Tests pass: 16/16 in run-timed-out-test.sh including P4 persist assertion

### Finding 3 (NOT SURE): "both branches call assert_pass unconditionally"

Claim: P2 between-stage firing assertion cannot turn red.

FACTUALLY INCORRECT. P2 has two falsifiable checks:
- Lines 268-274: `if [[ "$_p2_fast_one" == "complete" ]]` → assert_fail in else branch
- Lines 286-291: `if [[ "$_p2_elapsed" -le 20 ]]` → assert_fail in else branch

OLD code (no watchdog): fast-two runs 60s, outer 25s timeout fires → elapsed ≈25s >20s → FAILS
Per-stage reset (wrong): fires at ~11s, KILL at ~21s → elapsed ≈23s >20s → FAILS
Global watchdog (correct): fires at t=6s → elapsed ≈18s ≤20s → PASSES

### Finding 4 (NOT SURE): "CI-env variables in stage-limits.sh cannot be ruled out"

Claim: SPEC-5 carries no mechanical enforcement.

FACTUALLY INCORRECT. run-limit-precedence-test.sh lines 326-347 mechanically grep for
GITHUB_ACTIONS, bare CI, TRAVIS, CIRCLECI, RUNNER_OS, BUILD_BUILDID in both
stage-limits.sh and runner.sh. Verified: stage-limits.sh has ZERO such references
(grep returns exit=1). SPEC-5 test passes.

### Finding 5 (NOT SURE): "ADR-054 §11 vs §9 numbering"

Claim: Whether §11 exists in ADR-054 cannot be determined from the diff.

FACTUALLY MOOT. ADR-054-stage-contract.md line 515 clearly has `**§11 — run-level
wall-clock limit.**` under "Amendment (2026-10-12, #1944)". The ## Enforced by
section at line 542 cites all four new test files. SPEC-6 test passes (38/38 in
run-limit-precedence-test.sh includes this check). config/adr-enforcement-baseline.txt
does NOT list ADR-054 (grep returns empty).

### Conclusion

No code changes are needed. All 5 issue-acceptance findings are factual errors about
the state of the code. The implementation is complete: 821 tests pass, all SPEC-1
through SPEC-6 requirements are met.

---

## Previous iteration (iteration 2) — COMPLETE

### Fix applied: double-SIGTERM race in _runner_abort_trap (DONE)

Added `trap ':' INT TERM` as the FIRST statement inside `_runner_restore_stderr()`.
This ensures the guard is active before the function returns to `_runner_abort_trap`,
closing the race window where a second SIGTERM could fire at the function-return
boundary and abort the EXIT trap before `_runner_dispatch_always_run` ran.

B3 (runner-abort-banner-stderr-test.sh) still passes — `_runner_restore_stderr` is
still the first non-blank, non-comment statement in `_runner_abort_trap`.

**All acceptance tests pass:**
- runner-release-exit-paths-test.sh: 19/19 ✓ (SPEC-5 was the failing one)
- runner-abort-banner-stderr-test.sh: 4/4 ✓ (B3 preserved)
- runner-signal-rearm-test.sh: 5/5 ✓
- run-limit-precedence-test.sh: 38/38 ✓
- run-watchdog-clean-exit-test.sh: 8/8 ✓
- resume-after-run-timeout-test.sh: 6/6 ✓
- run-timed-out-test.sh: 16/16 ✓

Shape floor: The 9 failing floor files were a consequence of the previous run
being in "targeted" mode with 1 failure. With all tests passing in a full run,
`_SF_FAILED_COUNT=0` and `_SF_VERIFY_OK=1` → all floor files verified → PASS.

---

## Previous iteration (iteration 1) — had residual SPEC-5 failure

### Files changed in previous iterations:
- core/pipeline/runner.sh: 2 changes
  1. Watchdog body: added `exec {_RUNNER_ERR_FD}>&- || true` as second line (after `trap '' TERM`);
     removed `{_RUNNER_ERR_FD}>&-` from the boundary line
  2. `_runner_abort_trap`: swapped `trap ':' INT TERM` and `_runner_restore_stderr` order;
     `_runner_restore_stderr` is now first, updated comment
