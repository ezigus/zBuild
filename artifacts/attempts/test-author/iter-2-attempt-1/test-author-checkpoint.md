# Test Author Checkpoint — Iteration 4 COMPLETE

## All SPECs accounted for

### SPEC-1 [event-bus-timestamp-test.sh, lines 23-77]
Tests OSTYPE=darwin12.3.0 with mock date that outputs literal %3N. Checks:
- event emits to jsonl (not empty)
- no literal %3N in output
- ISO 8601 format YYYY-MM-DDTHH:MM:SS.NNNz
Status: COMPLETE, assertion present in file.

### SPEC-2 [event-bus-timestamp-test.sh, lines 79-138]
N1 (1 arg) vs N3 (3 args) jq call count comparison via JQ_CALL_LOG mock.
Old code: N3=N1+2 → FAIL. New code: N3==N1 → PASS.
Also checks payload fields are byte-preserved.
Status: COMPLETE. N1/N3 fix is in file (cumulative diff applied in iter 2/3).
Note: acceptance-gate SPEC-2 tautology finding is STALE — it found the old {($k): $v} assertion
from before the N1/N3 fix was applied. Current file has N1/N3 which is not a tautology.

### SPEC-3 [run-status-comment-loop-test.sh, lines 194-252]
Setup: custom gh mock injects event during PATCH. Waits 12s for first PATCH (timeout fix applied).
Then resets log, sleeps 3s, checks for spurious second PATCH.
Status: COMPLETE. Test fails if implementation incomplete (expected).

### SPEC-4 [run-status-comment-loop-test.sh, lines 254-303]
Waits 12s for first PATCH, then appends a non-rendering event, sleeps 4s,
checks no second PATCH fires.
Status: COMPLETE. Test fails if implementation incomplete (expected).

### SPEC-5 [run-status-comment-loop-test.sh, lines 305-360]
Starts sidecar with ZBUILD_EVENTS_JSONL=SC5_EVENTS. Checks SC5_EVENTS has
events after flush, and all have stage=run-status-comment.
Lint fix (|| true) applied at lines 339-342.
Status: COMPLETE.

### SPEC-6 [fork-budget-test.sh, lines 276-280]
FORK_BUDGET=4500 (already in file since iter 1). SPEC-4 assertion now has
[#1806/SPEC-6] tag added in iteration 4.
Status: COMPLETE.

### SPEC-7 [no testfile]
No-code SPEC — testfile(s) is empty. No assertion to write.
Status: N/A (no-code).

## Remaining known failures (NOT test issues)
- SPEC-3/SPEC-4 setup: "first PATCH fired" fails because build stage timed out.
  Implementation of run-status-comment.sh may be incomplete. Tests are CORRECT.
- fork-budget-test.sh: 5110 > 4500 because implementation (event-bus.sh) not yet patched.
  Once implementation reduces per-emit forks, this will pass.

## Changes made across all iterations
1. tests/unit/event-bus-timestamp-test.sh: SPEC-1 and SPEC-2 assertions added
2. tests/unit/run-status-comment-loop-test.sh: SPEC-3/4/5 assertions, timeout fixes, lint fix
3. tests/e2e/fork-budget-test.sh: FORK_BUDGET=4500 + [#1806/SPEC-6] tag on assertion
