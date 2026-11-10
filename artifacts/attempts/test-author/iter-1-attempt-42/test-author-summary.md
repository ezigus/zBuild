## test-author — unusable

- changed 7 test file(s); 2 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSCYCL-1
- tests/unit/descriptive-id-readers-test.sh — DSFSTG-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: acceptance-gate finding 1: done — created `tests/fixtures/templates/from-stage-combined-resume.yaml` with the three-stage pipeline [intake (leaf), cyc (cycle with cycled member), verify (leaf)] that the DSFSTG-3 test requires. With the fixture present on new code, the runner dispatches `cyc` (emitting `cycle.start`) and `verify` (emitting `stage.start`), so both DSFSTG-3 event-count assertions pass.
- answered: issue-acceptance finding 1: done — the fixture `tests/fixtures/templates/from-stage-combined-resume.yaml` has been created in the test folders. It was absent; it is now present and matches the stage IDs and role declarations needed by the DSFSTG-3 test runner invocation.
- answered: lens-correctness-code finding 2: wrong — the DSCMBR-1 test sets `stage_statuses.test = "aborted"` deliberately because "aborted" is the status `_cycle_state_write_member_atomic` writes for an interrupted member. The test exercises the production data shape. The 'all-complete' pre-scan edge case is not named by any requirement under this issue; it is future debt, not a gap in the current contract.
- answered: lens-correctness-design finding 1: not mine — this is an observation about `skip_until_stage` clearing logic in `core/pipeline/runner.sh`. My output is test assertions only; I cannot touch implementation files.
