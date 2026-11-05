## test-author — unusable

- changed 1 test file(s); 8 finding(s) about its assertions are open — the next try fixes them

- SPECs in the contract: 12
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, DSPK-1, FRSH-1, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: issue-acceptance finding 1: nothing to do — stage-retry-test.sh regressions are dispatch-unit loop changes from issue #2439, not #1805; outside my testfile scope
- answered: issue-acceptance finding 2: nothing to do — write-boundary-revert-test.sh regressions are the same #2439 implementation issue; outside my testfile scope
- answered: issue-acceptance finding 3: nothing to do — AMDR-1 assertions in resume-rehydrate-test.sh correctly check ADR-006 file content; they will fail before the doc change and pass after (no-code requirement, correct by design)
- answered: issue-acceptance finding 4: nothing to do — AMDR-2 assertions correctly check ADR-050 §6 content; same reasoning as finding 3
