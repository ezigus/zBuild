## test-author — unusable

- changed 0 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-red-team-code finding 1: done — The vacuous `stage.skip` count=0 assertions at DSFRSH-1 (lines ~844–855) and DSFRSH-2 (lines ~983–988) were replaced in Round 48 with non-vacuous `cycle.start > 0` assertions. The replacement is confirmed on disk: `grep -n "stage\.skip"` returns only a comment (line 966, the SPEC text); the actual assertions are `assert_gt` on `cycle.start` count. These CAN fail: if the dispatch-unit skip guard fires unconditionally, it skips intake → pipeline cannot proceed to dispatch `cyc` → `cycle.start` absent → count=0 → `assert_gt 0 > 0` → FAILS. After the code change (guard keyed on `resume_mode`), intake dispatches → `cyc` dispatched → PASSES.
- not answered: test-author finding 1
