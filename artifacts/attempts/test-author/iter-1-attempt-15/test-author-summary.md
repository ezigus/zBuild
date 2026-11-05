## test-author — unusable

- changed 1 test file(s); 13 finding(s) about its assertions are open — the next try fixes them

- SPECs in the contract: 13
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, DISP-1, FRSH-1, BNDY-1, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: issue-acceptance finding 1: nothing to do — the `stage-retry-test.sh` and `write-boundary-revert-test.sh` regressions are implementation failures in dispatch-unit loop changes for other issues (#2439). They are not in my testfile(s) scope.
- answered: issue-acceptance finding 2: nothing to do — same reason as finding 1.
- answered: issue-acceptance finding 3: nothing to do — the AMDR-1 assertions check the ADR-006 file content and are correct; they will fail before the doc change (ADR not yet amended) and pass after. That is the intended behavior for a no-code requirement.
- answered: issue-acceptance finding 4: nothing to do — same as finding 3; AMDR-2 assertions check ADR-050 §6 content correctly.
