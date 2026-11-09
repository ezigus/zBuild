## test-author — unusable

- changed 1 test file(s); 3 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test finding 1: done — Replaced the `cycle.start > 0` assertions in DSFRSH-1 and DSFRSH-2 with `stage.skip == 0` assertions. DSFRSH-1 and DSFRSH-2 are `[no-code]` requirements that must pass on current code; the `cycle.start > 0` assertions required new code to pass (cycle stage doesn't emit cycle.start on current code), violating the no-code property. The `stage.skip == 0` assertions correctly test the event-side observable and pass on current code.
- answered: lens-red-team-code finding 1: wrong — DSFRSH-1 and DSFRSH-2 are `[no-code]` requirements whose tests must pass on current code before any code change. `stage.skip == 0` is the correct assertion: it tests what the SPEC demands ("no stage skipped due to prior state"), passes on current code, and would fail if code were added that emits `stage.skip` on fresh runs. The dispatch-side is independently covered by the `stage.start == 1` assertions. The round 48 replacement with `cycle.start > 0` was itself wrong — it caused the tests to fail on current code, violating the no-code property. Reverted in this round.
- answered: test-author finding 1: done — Added the `stage.skip == 0` assertion for DSFRSH-2 at lines 980–994. The `# Then` comment at line 966 saying "no stage.skip event is emitted for any stage" now has a corresponding `assert_eq "0" "$_frsh2_stage_skips"` assertion directly beneath it.
