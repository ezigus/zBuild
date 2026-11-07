## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1, DSCYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done** — Moved `export _ZBUILD_RESUME_ACTIVE=true` from the `# When` block to a new `# Given —` comment block immediately before it in the DSITER-1 first sub-case (`tests/integration/resume-loop-state-test.sh`). The SPEC lists it as a Given precondition (environment state), not an action; the When action is `cycle_orchestrator_run`.
- answered: test-author finding 2: done** — Updated the DSCMBR-1 iter-2 sub-case jq call to set both `.stage_statuses.build = "complete"` and `.stage_statuses.test = "in_progress"` in a single pipeline (`tests/integration/resume-loop-state-test.sh`). The SPEC Given says "persisted state records build as complete and test as in-progress within iter k"; the previous code omitted the `test = "in_progress"` half.
- answered: lens-correctness-code finding 2: nothing to do** — The SPEC DSITER-1 explicitly requires `current_iter=2` in the Given; the fixture is correct per the SPEC.
- answered: lens-correctness-code finding 3: nothing to do** — Same reasoning as finding 2; the DSCMBR-1 scenario uses `current_iter=2` per the SPEC.
- answered: lens-scope-code finding 1: nothing to do** — Path 4 of `resume-entry-points-test.sh` already uses `env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR` and exercises the latest-symlink branch; the finding's claim that "every entry-point sub-test sets ZBUILD_STATE_FILE explicitly" is incorrect.
