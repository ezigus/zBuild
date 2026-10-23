# Build notes — issue #1801

## State at start of this call (iteration 2)

Previous issue-acceptance stage found 5 findings:
1. SPEC-3 isolation variant fails — no `sleep 5400` captured
2. npm test red — dispatch-rc-guard-test and stage-timeout-precedence-test fail
3. lifecycle.sh TERM trap uses `exit 143` (violates ADR-054 §4 {0,1})
4. Per-dispatch watchdog coverage uncertain while constraint is broken
5. SPEC-10 check uncertain due to lifecycle.sh broken state

## Investigation (iteration 2)

Both dispatch-rc-guard-test and stage-timeout-precedence-test PASS on the current
tree — they are NOT reproduced. This is consistent with the prior iteration's
comment fix having resolved the dispatch-rc-guard issue.

NEW failure found by running stage-timeout-process-group-test.sh:
  ✗ [#1801/SPEC-2] TERM trap exits with status 1 (positive: 'exit 1' in trap
    body, ADR-054 §4 {0,1})

Root cause: lifecycle.sh TERM traps use `exit 143`:
- Line 544: subshell trap ends with `exit 143`
- Line 555: non-subshell trap ends with `|| exit 143`

The test (stage-timeout-process-group-test.sh) uses an awk check that looks for
`exit 1[^0-9]` or `exit 1$` in the trap body. `exit 143` has `4` after `1`,
so it fails the `[^0-9]` guard.

The design decision explicitly requires `exit 1` (not 143):
"exit 1 unblocks the outer caller's wait identically to any other exit status,
while complying with ADR-054 §4 (plugin_hook_call must return {0,1}).
exit 143 would violate that constraint."

## Fix applied (iteration 2)

Changed `exit 143` → `exit 1` in both TERM traps in lifecycle.sh:
- Line 544: subshell trap: `exit 143'` → `exit 1'`
- Line 555: non-subshell fallback: `|| exit 143'` → `|| exit 1'`
- Updated comments at lines 525 and 534 to be accurate

## Verification

All 11 acceptance test files pass after the fix:
- stage-timeout-dispatch-test.sh: 18/18
- stage-timeout-process-group-test.sh: 7/7 ← was failing
- stage-timeout-precedence-test.sh: 6/6
- stage-timeout-loader-validation-test.sh: 7/7
- stage-timeout-retry-test.sh: 5/5
- stage-timeout-always-run-test.sh: 31/31
- stage-timeout-no-flat-limit-test.sh: 8/8
- orch-sequential-retired-guard-test.sh: 15/15
- orch-backend-misconfigured-test.sh: 8/8
- event-schema-emitted-coverage-test.sh: 10/10
- dispatch-rc-guard-test.sh: 36/36

## Answering issue-acceptance findings

Finding 1 (SPEC-3 isolation): NOT reproduced on this tree.
Finding 2 (npm test red): NOT reproduced — both dispatch-rc-guard-test and
  stage-timeout-precedence-test pass on this tree.
Finding 3 (exit 143 in TERM trap): FIXED — changed to exit 1.
Finding 4 (watchdog coverage): follows from finding 3 being fixed.
Finding 5 (SPEC-10 check): stage-timeout-dispatch-test passes (18/18).
