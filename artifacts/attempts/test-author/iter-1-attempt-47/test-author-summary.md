## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1, DSCYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSCYCL-1
- tests/unit/descriptive-id-readers-test.sh — DSFSTG-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: issue-acceptance finding 1: done — Added S12 sub-case in `tests/integration/from-stage-rehydrate-test.sh` (after line 831) that creates state under `$ZBUILD_STATE_ROOT/runs/<run_id>/pipeline-state.json` with `status=interrupted`, creates a `$ZBUILD_STATE_ROOT/latest` symlink, then invokes the runner with `env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR --from-stage cyc` (no `--resume`). Asserts exit 1, stderr contains `--from-stage is only valid with --resume`, and no `pipeline.resume` event is emitted. This test fails on the branch code (guard skipped for symlink path) and passes after the guard is extended.
- answered: lens-correctness-code finding 2: wrong — `"aborted"` is exactly the status `_cycle_state_write_member_atomic` writes for an interrupted cycle member (confirmed in the base code at `core/pipeline/cycle-orchestrator.sh`). DSCMBR-1 tests the interrupted-member case, which is what the requirement specifies: build=complete, test=aborted in the interrupted iteration. The "all complete" edge case (where every member carries `complete` from a prior pass) is a separate scenario not named or implied by any ISSUE REQUIREMENT, RQLOOP-1, or DSCMBR-1 in this contract.
- answered: lens-correctness-design finding 1: not mine — This finding concerns the interaction between `skip_until_stage` and `resume_mode` in `core/pipeline/runner.sh` — an implementation file I may not modify. The DSFSTG-3 test correctly asserts the observable requirement: `stage.start` (or `cycle.start`) is emitted for stages after `<s>` and no `stage.skip` events fire for any stage after `<s>`. The internal fix (`resume_mode=false` after clearing `skip_until_stage`) belongs to the code stage.
