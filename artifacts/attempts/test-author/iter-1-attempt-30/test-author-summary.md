## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1, DSCYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: review_lenses finding lens-correctness-code finding 2: done — changed `stage_statuses.test = "in_progress"` to `stage_statuses.test = "aborted"` in `resume-loop-state-test.sh` DSCMBR-1 iter=2 sub-case; "aborted" is the production value written by `_cycle_state_write_member_atomic`, so the skip-guard is now tested against the real data shape
- answered: review_lenses finding lens-scope-code finding 1: done — added S5 sub-case in `from-stage-rehydrate-test.sh` for `--from-stage` without `--resume`, exercising the `skip_restore=false` branch of `_runner_from_stage_preflight`; asserts intake artifact is rehydrated and no stage.start fires for intake
- not answered: lens-performance-code finding 1
- not answered: lens-red-team-code finding 1
- not answered: lens-red-team-code finding 2
- not answered: lens-red-team-code finding 3
- not answered: lens-correctness-code finding 1
- not answered: lens-correctness-code finding 2
- not answered: lens-correctness-code finding 3
- not answered: lens-scope-code finding 1
- not answered: lens-sre-code finding 1
- not answered: lens-sre-code finding 2
- not answered: lens-correctness-design finding 1
