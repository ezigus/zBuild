## test-author — unusable

- changed 0 test file(s); 2 finding(s) about its assertions are open — the next try fixes them

- SPECs in the contract: 11
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, BNDY-1, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: nothing to do — `resume-loop-state-test.sh` lines 105–144 already contain the `[#1805/ITER-1]`-tagged guard sub-test covering the nested-loop re-entry clause. Present and correct.
- answered: issue-acceptance finding 1: nothing to do — stage-retry and write-boundary-revert regressions are in unrelated test files caused by implementation dispatch-loop changes; outside test-author scope.
- answered: issue-acceptance finding 2: nothing to do — same files, same cause; outside scope.
- answered: issue-acceptance finding 3: nothing to do — AMDR-1 correctly checks all required ADR-006 phrases; will pass once the implementation amends the doc.
- answered: issue-acceptance finding 4: nothing to do — AMDR-2 correctly checks all required ADR-050 §6 phrases; will pass once the doc is amended.
