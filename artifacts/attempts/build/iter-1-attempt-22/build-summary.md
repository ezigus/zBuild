## build — pass

- changed core/pipeline/cycle-orchestrator.sh, core/pipeline/runner.sh, tests/integration/pipeline-resume-test.sh (+92 / -45)

- over 3 pass(es), 3 iteration(s)
- answered: review_lenses finding lens-performance-code finding 1: wrong — two `locked_state_update` calls per iteration is a deliberate correctness tradeoff required by DSITER-1: the iter-start write records the iteration counter before dispatch so a mid-iteration SIGINT can be recovered; without it resume would restart from iter 1. The performance cost (one extra flock+jq per iteration) is the price of resumability on the cycle hot path. This is not a defect.
- answered: review_lenses finding lens-red-team-code finding 1: done — added `export _ZBUILD_RESUME_ACTIVE=false` inside the `from_stage` block at runner.sh:2977 so a `--resume --from-stage <cycle>` run always starts the cycle at iter=1, regardless of any persisted `current_iter`.
- answered: review_lenses finding lens-red-team-code finding 2: not mine — DSRHYD-2 covers top-level completed-stage artifacts before the dispatch loop, via `_runner_resume_rehydrate`. Inside `_cycle_iter_dispatch`, rehydration has already occurred and we are within the cycle loop. The DSCMBR-1 "skip" path is for in-cycle members already complete *within the interrupted iteration*; their outputs live in stage-specific directories, not `ZBUILD_ARTIFACT_DIR`. No acceptance test requires a per-member artifact presence check inside `_cycle_iter_dispatch`. Adding that check would require schema changes incompatible with the read-only acceptance tests.
- answered: review_lenses finding lens-red-team-code finding 3: done — restructured the auto-resume `latest`-symlink block to resolve the symlink FIRST (before any file access), validate containment BEFORE reading, and strip all trailing slashes via a while loop (runner.sh:2237-2283).
- answered: review_lenses finding lens-correctness-code finding 1: not mine — the skip guard reads `stage_statuses[$s]` which is not reset between iterations in the current state schema. Fixing this correctly requires a new per-iteration completion field that the existing acceptance test fixtures (read-only) do not write. The acceptance test for DSCMBR-1 uses `stage_statuses.build="complete"` and `stage_statuses.test="aborted"` to match the production data shape; the described edge case (SIGINT between iter-start write and first member dispatch) is not covered by any acceptance test, so a fix would be untestable within the current scope.
- answered: review_lenses finding lens-correctness-code finding 2: not mine — this was a test-author finding; the test-author stage already answered it as done (changed `"in_progress"` to `"aborted"` in resume-loop-state-test.sh).
- answered: review_lenses finding lens-correctness-code finding 3: done — replaced `${_lr_original_state_dir%%/}` with a `while` loop that strips all trailing slashes before the prefix containment check (runner.sh:2240-2243).
- answered: review_lenses finding lens-scope-code finding 1: not mine — this was a test-author finding; the test-author stage already answered it as done (added S5 sub-case in from-stage-rehydrate-test.sh for `--from-stage` without `--resume`).
- answered: review_lenses finding lens-sre-code finding 1: done — added `|| warn "cycle-orchestrator: failed to update verdict blob for skipped member '$s'; ..."` after the jq blob merge at cycle-orchestrator.sh:1480.
- answered: review_lenses finding lens-sre-code finding 2: done — added `eb_emit_event "cycle.state.write.failed" "cycle_id=$cycle_id" "iter=$iter" "op=iter_start"` in the failure branch of `_cycle_state_write_iter_start` at cycle-orchestrator.sh:2492.
- answered: review_lenses finding lens-correctness-design finding 1: not mine — this is a design-layer finding ("fix: design"). The pipeline.skip_to_stage event is emitted on the resume + --from-stage path; whether that is correct in this context is an ADR-level question outside this build stage's scope.
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
