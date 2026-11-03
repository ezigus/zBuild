## test-author — unusable

- changed 5 test file(s); 3 finding(s) about its assertions are open — the next try fixes them

- SPECs in the contract: 11
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, BNDY-1, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: nothing to do — the RHYD-1 assertions check `assert_file_exists` for the restored artifact and `assert_contains` for content matching the git state branch; these are the only functions that together produce the effect, so failing to call them produces a failing assertion.
- answered: test-author finding 2: nothing to do — FSTG-1 has all four assertions tagged including `assert_file_exists` and `assert_contains` for artifact rehydration; these fail when the implementation doesn't call `_artifact_persist_restore` + `_artifact_persist_put_back`.
- answered: test-author finding 3: done — FSTG-2's stderr check already checks for `"has no restorable primary artifact"` (from previous round); it is now properly tagged `[#1805/FSTG-2]`.
