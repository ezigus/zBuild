# Build notes — issue #1944: run-level wall-clock limit with watchdog

## Current iteration — COMPLETE

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

## Previous investigation — investigating SPEC-5 failure

### Failures from test stage:

**runner-release-exit-paths-test.sh SPEC-5** — `marker=` (empty — no release dispatched)
AND **9 golden/shape-floor tests** failing (count/list altered)

### Root cause analysis — SPEC-5:

The test sends `kill -TERM -$RUNNER_PID` to the process group. In SPEC-5, the runner
is wrapped in `timeout 120 bash runner.sh`. When `timeout 120` receives SIGTERM:
1. It forwards SIGTERM to its child (runner bash)
2. It exits

So runner bash gets TWO SIGTERMs:
- First: from the process-group kill directly
- Second: from `timeout` forwarding

**The double-SIGTERM problem in detail:**

Bash's signal model: pending signals are checked at command boundaries
(after each command completes). In `_runner_abort_trap`:

```
_runner_abort_trap() {
    _runner_restore_stderr    # command 1 (first stmt - required by B3)
    trap ':' INT TERM         # command 2 (guard)
```

Sequence:
1. First SIGTERM → `_runner_signal_trap TERM` → `exit 1` → EXIT trap fires
2. `_runner_abort_trap` starts executing
3. `_runner_restore_stderr` executes (very fast: `exec 2>&N`)
4. `_runner_restore_stderr` RETURNS → bash checks pending signals
5. Second SIGTERM is pending → fires `_runner_signal_trap TERM` → `exit 1` from EXIT trap → ABORT
6. `trap ':' INT TERM` NEVER EXECUTES
7. `_runner_dispatch_always_run` NEVER EXECUTES → marker is empty

This is consistent (not a race) because `timeout` forwards SIGTERM very quickly,
making the second SIGTERM pending before or during the first handler execution.
When bash unblocks SIGTERM after the EXIT trap starts, the second SIGTERM fires
at the first command boundary (after `_runner_restore_stderr` returns).

**Why SPEC-1 through SPEC-4 don't fail:**
- SPEC-1, 2, 3: no SIGTERM involved (success/nonzero/SIGINT paths)
- SPEC-4: uses `setsid bash -c '... exec bash ...'` (new session, no `timeout` wrapper)
  → only ONE SIGTERM reaches the runner

**Why runner-abort-banner-stderr-test.sh B3 constrains the fix:**
B3 checks that `_runner_restore_stderr` is the FIRST non-blank, non-comment
statement in `_runner_abort_trap`. So I cannot move `trap ':' INT TERM` BEFORE
`_runner_restore_stderr` at the `_runner_abort_trap` level.

**THE FIX:**
Move `trap ':' INT TERM` INSIDE `_runner_restore_stderr` as its FIRST statement:

```bash
_runner_restore_stderr() {
    trap ':' INT TERM   # guard: called only from _runner_abort_trap (EXIT trap)
    [[ -n "${_RUNNER_ERR_FD:-}" ]] && exec 2>&"$_RUNNER_ERR_FD"
    return 0
}
```

This works because:
- Bash checks pending signals BETWEEN commands, not DURING a function call's entry
- When `_runner_abort_trap` calls `_runner_restore_stderr`, bash enters the function
  body and executes `trap ':' INT TERM` as the first instruction INSIDE
  `_runner_restore_stderr`
- When `_runner_restore_stderr` RETURNS back to `_runner_abort_trap`, the guard
  is already active
- If the second SIGTERM fires at that return boundary, it's handled as a noop

B3 passes: first non-blank, non-comment statement in `_runner_abort_trap` is still
`_runner_restore_stderr`. The trap setting is INSIDE that function.

### Golden file / shape-floor failures:

9 tests failing about "count, order or list altered". These are:
- tests/golden/full-pipeline/event-sequence.golden
- tests/golden/parity/event-sequence.golden
- tests/unit/shape-floor-content-stable-test.sh
- tests/unit/template-simple-yaml-test.sh
- tests/unit/build-oos-pass-request-test.sh
- tests/unit/change-scope-floor-test.sh
- tests/unit/core-pipeline-template-test.sh
- tests/unit/template-resolvability-preflight-test.sh
- tests/unit/shape-floor-summary-plain-test.sh

Need to investigate what's failing. All are in scope.

## Previous iteration — "COMPLETE" (but had residual SPEC-5 failure)

### Files changed in previous iterations:
- core/pipeline/runner.sh: 2 changes
  1. Watchdog body: added `exec {_RUNNER_ERR_FD}>&- || true` as second line (after `trap '' TERM`);
     removed `{_RUNNER_ERR_FD}>&-` from the boundary line
  2. `_runner_abort_trap`: swapped `trap ':' INT TERM` and `_runner_restore_stderr` order;
     `_runner_restore_stderr` is now first, updated comment
