## review-lens-red-team — fail

- found: high: A persisted `current_iter` larger than `_CYCLE_MAX_ITER` causes the iteration loop to execute zero times on resume, then fall through to the post-loop `unconverged` path (line 2954), so the entire cycle's work is skipped; with `on_max=continue`, downstream stages (review, pr, deploy) then run against unbuilt code. (core/pipeline/cycle-orchestrator.sh:2416) (and 1 more)

- high: A persisted `current_iter` larger than `_CYCLE_MAX_ITER` causes the iteration loop to execute zero times on resume, then fall through to the post-loop `unconverged` path (line 2954), so the entire cycle's work is skipped; with `on_max=continue`, downstream stages (review, pr, deploy) then run against unbuilt code. (core/pipeline/cycle-orchestrator.sh:2416)
- medium: The DSCMBR-1 member-skip path skips a cycle member marked complete without verifying its primary artifact is present after rehydration; DSRHYD-2 requires exit 1 before any stage.start when a complete stage's artifact is absent, but `stage.start` for the interrupted member at line 1497 fires even when a skipped member's artifact is gone. (core/pipeline/cycle-orchestrator.sh:1474)
- score: 5
