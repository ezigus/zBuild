## test-author — fail

- changed 2 test file(s); 3 finding(s) about its assertions still open after 2 round(s)

- SPECs in the contract: 9
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12
- tests/integration/from-stage-rehydrate-test.sh — SPEC-3, SPEC-4
- tests/integration/resume-loop-state-test.sh — SPEC-7
- tests/integration/resume-entry-points-test.sh — SPEC-9
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test finding 5: done — removed `cycled` dispatch assertion from resume-entry-points-test.sh SPEC-13 sub-case; SPEC-9 requires artifact restoration (assert_file_exists), not cycled dispatching
- answered: test finding 6: done — fixed `grep -c ... || echo 0` double-output bug in all three SPEC-1 intake_starts variables using `wc -l | tr -d ' '`
- answered: acceptance-gate finding 1: done — same fix; with wc -l, `assert_eq "0" "0"` will pass on new code
- answered: issue-acceptance finding 3: nothing to do — `assert_eq "2" "$_SPEC7_FIRST_ITER"` in resume-loop-state-test.sh covers the full SPEC-7 requirement; the removed assertion was about `cycle.iteration.complete` events which SPEC-7 doesn't require; the first_iter==2 assertion proves both "starts from current_iter" and "iter-1 stages not re-dispatched"
- answered: test-author finding 1: nothing to do — `assert_file_exists` (line 114) and `assert_contains` (line 125) for SPEC-3 artifact placement both carry `[#1805/SPEC-3]` in their labels; the finding describes a prior state before a previous test-author call fixed the tagging.
- answered: test-author finding 2: nothing to do — `assert_contains` (line 213) for SPEC-4 stderr naming carries `[#1805/SPEC-4]` in its label; the finding describes a prior state before a previous test-author call fixed the tagging.
