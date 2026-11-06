## test-author — pass

- tests for RHYD-1, RHYD-2, FSTG-1, FSTG-2, AMDR-1, AMDR-2, ITER-1, SKIP-1, DSPK-1, ENTR-1, ENTR-2, FRSH-1, FRSH-2, DLGT-1, CYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, SKIP-1, DSPK-1, FRSH-1, FRSH-2, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1, ENTR-2
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — added `_p4_first_start_lineno` capture and `assert_gt "[#1805/ENTR-2] auto-resume via latest symlink: pipeline.resume precedes first stage.start (artifact restored before dispatch loop)"` to the ENTR-2 section of `resume-entry-points-test.sh`.
- answered: issue-acceptance finding 1: nothing to do — ENTR-1 state IS at `runs/<run_id>/` for all three paths (round-30 fix). ENTR-2 specifically tests auto-resume state discovery via the `latest` symlink WITHOUT `ZBUILD_STATE_FILE` set, which is the discriminating test for "runner finds state in `runs/<run_id>/`" for the auto-resume path. Paths 1 and 3 use explicit state file/dir pointing to `runs/<run_id>/` — that is their correct invocation model (they don't discover; they're told). The code-level concern (runner doesn't scan `runs/<run_id>/` for auto-resume without latest symlink) is covered by ENTR-2's discriminating assertion.
