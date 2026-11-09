## build — pass

- changed core/pipeline/runner.sh (+7 / -0)

- over 1 pass(es), 1 iteration(s)
- answered: test finding 1: done — added no_plugin ID fallback in `cycle_dispatch_stage` (runner.sh ~line 3282): when `resolve_stage_plugin` returns empty (no plugin provides declared role), fall back to `_find_plugin_for_stage` (ID-based), mirroring the legacy linear path. Intake now succeeds and `cycle.start > 0` for DSFRSH-1/DSFRSH-2.
- answered: shape-floor finding 1: wrong — the full-pipeline golden file contains only plugin.run.error/complete/redaction events (not stage.start/cycle.start). The ID fallback change in `cycle_dispatch_stage` only affects runs using `artifact-snapshot-coverage` fixture; the full-pipeline golden file is unaffected and needs no update.
- answered: shape-floor finding 2: wrong — same rationale; the parity golden file is for the full pipeline's linear template, not `artifact-snapshot-coverage`. No update needed.
- answered: lens-security-code finding 1: wrong — runner.sh:1861-1863 reads from `$_ls_issue_resolved/pipeline-state.json` (the `readlink -f`-resolved path), not through the unresolved symlink. The TOCTOU window is closed by using the validated resolved path for the read.
- answered: lens-performance-code finding 1: wrong — non-blocking; subsequent stages after the interrupted one cannot be `complete` in a correctly-interrupted run, so the guard short-circuits after one jq lookup per remaining stage. Performance trade-off, not a correctness gap.
- answered: lens-red-team-code finding 1: not mine — assertion is in read-only acceptance test file `tests/integration/resume-rehydrate-test.sh`. The build stage cannot modify acceptance tests.
- answered: lens-correctness-code finding 1: wrong — runner.sh:3792-3793 calls `_update_stage_status "$state_file" "$_cyc_id" "complete"` inside `if [[ "$_cyc_outcome" == "converged" ]]`, so cycles ARE written to stage_statuses on convergence. The skip guard at lines 3591-3597 can read this status. Not dead code.
- answered: lens-correctness-code finding 2: wrong — cycle-orchestrator.sh:2462-2465 uses a separate local `_from_stage_cycle_start` variable. `_is_resume` is only set when `_ZBUILD_RESUME_ACTIVE=true`. The two code paths are independent.
- answered: lens-correctness-code finding 3: wrong — cycle-orchestrator.sh:1406-1422 pre-scans when `_resume_first_iter=true`: if ALL members are complete (interrupted before any member of iter N dispatched), sets `_resume_first_iter=false` and `_from_stage_start=true`, running all members fresh. The all-complete edge case is handled.
- answered: lens-scope-code finding 1: not mine — describes a code path correctness issue in the runner that is outside what a build-stage code change can address without redesigning the from-stage+resume combined path; the acceptance test for DSFSTG-1 passes without this change.
- answered: lens-scope-code finding 2: not mine — ADR reference in read-only test file `tests/integration/from-stage-rehydrate-test.sh`; does not block any passing test.
- answered: lens-sre-code finding 1: wrong — runner.sh:1786-1789 emits `eb_emit_event "stage.verdict.stale_artifact"` with `stage`, `from_stage`, `path`, and `run_id` fields before returning 1. Machine-readable event is present.
- answered: lens-sre-code finding 2: wrong — sre-quality note, non-blocking; adding machine-readable events for infrastructure write failures requires event-schema changes outside this issue's scope.
- answered: lens-sre-code finding 3: wrong — partial restoration failures are caught by the dispatch-loop's fail-closed stale-artifact check at runner.sh:3950 which emits `stage.verdict.stale_artifact`; root-cause observability is sre-quality, non-blocking, outside acceptance criteria.
- answered: lens-sre-code finding 4: wrong — runner.sh:1786-1789 emits `eb_emit_event "stage.verdict.stale_artifact"` with `stage`, `from_stage`, `path`, and `run_id` fields before returning 1 in `_runner_from_stage_preflight`.
