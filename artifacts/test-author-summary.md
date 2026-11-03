## test-author — fail

- changed 2 test file(s); 3 finding(s) about its assertions still open after 2 round(s)

- SPECs in the contract: 11
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12, SPEC-14
- tests/integration/from-stage-rehydrate-test.sh — SPEC-3, SPEC-4, SPEC-14
- tests/integration/resume-loop-state-test.sh — SPEC-7
- tests/integration/resume-entry-points-test.sh — SPEC-9
- tests/unit/hydrate-stage-test.sh — SPEC-13
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test finding 1: nothing to do — `assert_file_exists` for the restored artifact is correct; failure means the implementation doesn't call `_artifact_persist_restore` + `_artifact_persist_put_back` before the dispatch loop (code failure, not a test bug)
- answered: test finding 2: nothing to do — `assert_eq "0" "$_s1_intake_starts"` is correct; the failure means the dispatch loop still dispatches completed stages on resume (code failure, not a test bug)
- answered: acceptance-gate finding 1: done — changed `assert_contains` in from-stage-rehydrate-test.sh SPEC-4 from checking `"intake"` to checking `"has no restorable primary artifact"` — this phrase appears only in the new `_runner_from_stage_preflight` at runner.sh:1751 and is absent from old code, so the assertion now fails on old code and passes only after the new function is present
- answered: acceptance-gate finding 2: nothing to do — SPEC-1/SPEC-2/SPEC-3 tests are correct; they fail on new code because the implementation doesn't yet meet the requirements (dispatch loop still re-dispatches completed stages, rehydration not wired to cyclic template path); these are code failures, not test failures
