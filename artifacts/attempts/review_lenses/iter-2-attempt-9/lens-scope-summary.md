## review-lens-scope — fail

- found: medium: The new latest-symlink auto-resume branch (Gap 8 fix, `elif ! $no_resume && [[ -z "${ZBUILD_STATE_FILE:-}" && -L "$state_dir/latest" ]]`) is exercised by no test: every entry-point sub-test in `resume-entry-points-test.sh` sets `ZBUILD_STATE_FILE` explicitly, which routes auto-resume through the pre-existing flat-file `elif` at line 2190, leaving the new branch unreachable in the test suite. (core/pipeline/runner.sh:2209) (and 1 more)

- medium: The new latest-symlink auto-resume branch (Gap 8 fix, `elif ! $no_resume && [[ -z "${ZBUILD_STATE_FILE:-}" && -L "$state_dir/latest" ]]`) is exercised by no test: every entry-point sub-test in `resume-entry-points-test.sh` sets `ZBUILD_STATE_FILE` explicitly, which routes auto-resume through the pre-existing flat-file `elif` at line 2190, leaving the new branch unreachable in the test suite. (core/pipeline/runner.sh:2209)
- low: `_hydrate_put_back` is now dead production code — `hydrate_run` calls `_artifact_persist_put_back` instead — but the function is left in place and is still called directly by the out-of-scope test `tests/integration/prior-work-reuse-integration-test.sh:114`, so that test now verifies a function no production path reaches rather than the live `_artifact_persist_put_back` implementation. (plugins/tool/hydrate/plugin.sh:64)
- score: 7
