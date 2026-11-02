## test-author — fail

- changed 4 test file(s); 2 finding(s) about its assertions still open after 2 round(s)

- SPECs in the contract: 9
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12
- tests/integration/from-stage-rehydrate-test.sh — SPEC-3, SPEC-4
- tests/integration/resume-loop-state-test.sh — SPEC-7
- tests/integration/resume-entry-points-test.sh — SPEC-9
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test finding 3: nothing to do — the [#1805/SPEC-3] "intake emits no stage.start when skipped via --from-stage" assertion is correct; it fails because the new code's --from-stage implementation still dispatches intake. The test correctly identifies the implementation gap.
- answered: test finding 6: done — added `ZBUILD_CYCLES_ENABLED=1` to the SPEC-13 runner invocation in resume-entry-points-test.sh; without it the cycle was suppressed and cycled_starts=0.
- answered: test finding 7: done — removed the `_s7_iter1_complete` assertion from resume-loop-state-test.sh; the spec requires "no stage.start for iter-1" (not "no cycle.iteration.complete"), and the `first_iter==2` assertion already covers the requirement correctly.
- answered: test finding 8: nothing to do — the [#1805/SPEC-1] "intake emits no stage.start" assertions are correct; they fail because the new code rehydrates artifacts but still dispatches completed stages. The tests correctly identify the remaining implementation gap. The SPEC-12/SPEC-13 cycle failures (2 of the 5) are fixed by adding ZBUILD_CYCLES_ENABLED=1.
- answered: acceptance-gate finding 1: nothing to do for SPEC-1/SPEC-3 (tests are correct, code is wrong); done for SPEC-7 (removed overly-strict iter.complete assertion), SPEC-12/SPEC-13 (added ZBUILD_CYCLES_ENABLED=1).
- answered: test finding 3: done — fixed `grep -c ... || echo 0` double-output bug: replaced with `jq -r 'select(...and .data.stage=="intake") | .type' | wc -l | tr -d ' '` so the count is always a single "0" when no matches, not "0\n0".
