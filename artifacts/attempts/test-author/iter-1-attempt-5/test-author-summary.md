## test-author — unusable

- changed 2 test file(s); 8 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: DSCLA-1: tests/integration/teardown-repeat-signal-test.sh stopped before DSCLA-1's assertion ran on the code from before this change (exit 12): done — the spurious `exit "$FAIL"` between T5 and the DSCLA section was removed in a prior pass. The current file has no early exit before `[DSCLA-1/5]`; on base code the assertion correctly fails because `zbuild_claim_acquire` does not exist and the stage never sees `zbuild:claimed`.
- answered: issue-acceptance finding 1: The issue requires this and the change does not meet it: RQCLA-3 `pipeline.refused.claimed` is not registered in `config/event-schema.json`: not mine — `config/event-schema.json` is an implementation file outside the test folders I may touch. My DSCLA-10 test asserts its presence and correctly fails on base code. The fix belongs to the code stage.
- not answered: issue-acceptance finding 1
