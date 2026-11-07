## test-author — pass

- tests for RHYD-1, RHYD-2, FSTG-1, FSTG-2, AMDR-1, AMDR-2, ITER-1, CMBR-1, SKIP-1, DSPK-1, ENTR-1, ENTR-2, FRSH-1, FRSH-2, DLGT-1, CYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, SKIP-1, DSPK-1, FRSH-1, FRSH-2, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1, CMBR-1
- tests/integration/resume-entry-points-test.sh — ENTR-1, ENTR-2
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test finding 1: done — removed the wrong `[#1805/FRSH-1]` assertion from `cycle-member-dispatch-events-test.sh`; it asserted behavior that is both impossible (stub blocks the guard) and incorrect (correct code uses `_ZBUILD_RESUME_ACTIVE` check, not bare `_cd_iter > 0`). FRSH-1 is already correctly covered in `resume-rehydrate-test.sh`.
- answered: test finding 2: done — removed the FRSH-2 `cycle.start > 0` assertion from `resume-rehydrate-test.sh`; the FRSH-2 runner exits after intake and never reaches `cyc`, so `cycle.start = 0` is structural, not a skip-guard signal. The two existing assertions cover FRSH-2 adequately.
- answered: issue-acceptance finding 1: nothing to do — path 4 (lines 425–550 of `resume-entry-points-test.sh`) correctly exercises ENTR-2 using `env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR`; the test passes (not in the failing list). The finding's reference to path 2 setting `ZBUILD_STATE_FILE` is accurate but path 2 is an ENTR-1 sub-case, not ENTR-2.
- answered: issue-acceptance finding 2: nothing to do from test-author — this is a code finding (missing `_ZBUILD_RESUME_ACTIVE` check in `runner.sh`). The wrong assertion that validated the buggy behavior has been removed. FRSH-1/GUAR-1 is correctly tested in `resume-rehydrate-test.sh`.
