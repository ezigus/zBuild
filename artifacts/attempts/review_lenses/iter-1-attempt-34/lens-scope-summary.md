## review-lens-scope — fail

- found: medium: The `skip_restore=false` restore-and-put_back branch inside `_runner_from_stage_preflight` is unreachable from `main()`: the guard `if [[ -n "$from_stage" ]] && ! $resume_mode` at line 2313 returns 1 before the preflight call whenever `resume_mode=false`, and the preflight is called at line 3100 with `"$resume_mode"` as `skip_restore`, which is always `true` when `from_stage` is set, so the git-restore step (lines 1746–1754) never executes. (core/pipeline/runner.sh:1743) (and 2 more)

- medium: The `skip_restore=false` restore-and-put_back branch inside `_runner_from_stage_preflight` is unreachable from `main()`: the guard `if [[ -n "$from_stage" ]] && ! $resume_mode` at line 2313 returns 1 before the preflight call whenever `resume_mode=false`, and the preflight is called at line 3100 with `"$resume_mode"` as `skip_restore`, which is always `true` when `from_stage` is set, so the git-restore step (lines 1746–1754) never executes. (core/pipeline/runner.sh:1743)
- low: The header comment references `ADR-006 §3.5`, but the step being tested (`_runner_from_stage_preflight`, added for `--from-stage` rehydration) is `§3.6` — the new step introduced by this PR. (tests/integration/from-stage-rehydrate-test.sh:3)
- low: The header comment references `ADR-006 §3.5`, but the step being tested (`_runner_resume_rehydrate` called on all three entry paths) is `§3.6` — the new step introduced by this PR. (tests/integration/resume-entry-points-test.sh:3)
- score: 8
