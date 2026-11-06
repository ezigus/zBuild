## review-lens-scope — fail

- found: medium: The diff emits `stage.start` for ALL cycle member dispatches (iter > 0), not just the interrupted stage k, changing the event contract for every cycle-based pipeline run including fresh runs — this is broader than what DSPK-1 and the issue requested. (core/pipeline/runner.sh:3166) (and 2 more)

- medium: The diff emits `stage.start` for ALL cycle member dispatches (iter > 0), not just the interrupted stage k, changing the event contract for every cycle-based pipeline run including fresh runs — this is broader than what DSPK-1 and the issue requested. (core/pipeline/runner.sh:3166)
- medium: Path 2 (auto-resume) passes ZBUILD_STATE_FILE explicitly, bypassing the actual bug the issue describes: 'auto-resume reads $state_dir/pipeline-state.json before the run switches to runs/<run_id>/, so it may never find the interrupted run's state'; R5/PATH-1/ENTR-1 explicitly requires that the auto-resume path 'finds the interrupted run's state in runs/<run_id>/' — the test does not prove this. (tests/integration/resume-entry-points-test.sh:212)
- low: `_runner_from_stage_preflight` is declared with 4 parameters but reads `$_runner_issue` as a global rather than accepting issue as a 5th argument, while the companion function `_runner_resume_rehydrate` takes issue explicitly as `$1`. (core/pipeline/runner.sh:1734)
- score: 7
