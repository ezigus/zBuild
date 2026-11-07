## review-lens-performance — fail

- found: medium: The `iter > 0` guard is always true (the loop starts at `_start_iter` ≥ 1), so `eb_emit_event "stage.start"` fires for every cycle member in every iteration on every run—fresh runs included—adding an unconditional I/O call to the innermost dispatch hot path where none existed before. (core/pipeline/cycle-orchestrator.sh:1866) (and 1 more)

- medium: The `iter > 0` guard is always true (the loop starts at `_start_iter` ≥ 1), so `eb_emit_event "stage.start"` fires for every cycle member in every iteration on every run—fresh runs included—adding an unconditional I/O call to the innermost dispatch hot path where none existed before. (core/pipeline/cycle-orchestrator.sh:1866)
- low: On the first resumed iteration the CMBR-1 guard forks a `jq` subprocess for each cycle member to read its status from the state file, rather than reading and caching the relevant section once before the member loop. (core/pipeline/cycle-orchestrator.sh:1444)
- score: 6
