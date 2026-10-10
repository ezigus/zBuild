# Test Author Checkpoint — Iteration 4 COMPLETE (final)

## All SPECs accounted for

### SPEC-1 [event-bus-timestamp-test.sh, lines 23-89]
Tests OSTYPE=darwin12.3.0 with mock date that outputs literal %3N.
Precondition assertions for ZBUILD_PLATFORM=linux and OSTYPE=darwin* added.
Checks: no literal %3N, ISO 8601 format YYYY-MM-DDTHH:MM:SS.NNNz.
Status: COMPLETE.

### SPEC-2 [event-bus-timestamp-test.sh, lines 91-168]
N1 (1 arg) vs N3 (3 args) jq call count comparison via JQ_CALL_LOG mock.
Tautology fix applied in this iteration: condition changed from
`$_n3 -eq $_n1` to `$_n1 -gt 0 && $_n3 -eq $_n1` so the assert_pass
can never fire when N1=N3=0 (mock not intercepted on old code).
Also checks payload fields: all 3 data fields present + type + schema_version.
Status: COMPLETE — tautology eliminated.

### SPEC-3 [run-status-comment-loop-test.sh, lines 194-260]
Custom gh mock injects event during PATCH to simulate redaction.applied.
Waits 12s (120*0.1) for first PATCH, resets log, sleeps 3s, checks no
spurious second PATCH. Alive check proves loop ran another cycle.
Status: COMPLETE. Test fails on old code (no impl).

### SPEC-4 [run-status-comment-loop-test.sh, lines 262-322]
Non-rendering event appended after first PATCH, waits 4s.
Added alive check in this iteration: sidecar must still be alive after
the sleep to prove the loop polled, making the zero-PATCH result non-vacuous.
Status: COMPLETE — alive check added.

### SPEC-5 [run-status-comment-loop-test.sh, lines 313-392]
Checks SC5_EVENTS has events, all carry stage=run-status-comment.
Added redaction.applied check in this iteration: `grep -qF '"redaction.applied"'`
directly on SC5_EVENTS to verify the "(including redaction.applied)" condition.
Status: COMPLETE — redaction.applied check added.

### SPEC-6 [fork-budget-test.sh, lines 276-283]
FORK_BUDGET=4500. Added in this iteration: assert_eq checking
FORK_BUDGET < 5480 (the merge-base measurement) to prove unpatched code fails.
Status: COMPLETE — baseline comparison added.

### SPEC-7 [no testfile]
No-code SPEC — testfile(s) is empty. No assertion to write.
Status: N/A.

## Changes made in this iteration (iteration 4)
1. event-bus-timestamp-test.sh line 142: `$_n3 -eq $_n1` → `$_n1 -gt 0 && $_n3 -eq $_n1`
2. run-status-comment-loop-test.sh: alive check added to SPEC-4 section
3. run-status-comment-loop-test.sh: redaction.applied grep added to SPEC-5 section
4. fork-budget-test.sh: assert_eq for FORK_BUDGET < 5480 added before budget check

## Known failing assertions (implementation not yet written)
- [#1806/SPEC-3] first PATCH fired (setup): sidecar doesn't fire PATCH on old code
- [#1806/SPEC-4] first PATCH fired (setup): same
- [#1806/SPEC-6] external execs <= FORK_BUDGET: 5111 > 4500 until event-bus.sh is patched
These are correct failures — the test is right, the implementation is missing.
