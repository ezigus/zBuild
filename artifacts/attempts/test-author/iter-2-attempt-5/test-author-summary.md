## test-author — unusable

- changed 1 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, SKIP-1, DSPK-1, FRSH-1, FRSH-2, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1, ENTR-2
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: issue-acceptance finding 1: done — added [#1805/ENTR-2] test section to `tests/integration/resume-entry-points-test.sh` (PATH 4). The test sets `ZBUILD_STATE_ROOT` to a temp dir, creates `$ZBUILD_STATE_ROOT/runs/<run_id>/pipeline-state.json` with `status=interrupted` and `intake=complete`, snapshots the intake artifact to the git state branch, creates `$ZBUILD_STATE_ROOT/latest` symlink pointing to the per-run dir, invokes the runner with `ZBUILD_STATE_FILE` and `ZBUILD_STATE_DIR` unset (via `env -u`), and asserts: `pipeline.resume` event emitted (auto-resume fired), completed-stage artifact restored, no `stage.start` for intake. This test will FAIL before the code change (state file at `$ZBUILD_STATE_ROOT` doesn't exist so runner starts fresh — no `pipeline.resume`) and PASS after (runner follows `latest` symlink to find state).
