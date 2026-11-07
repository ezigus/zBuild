## review-lens-sre — fail

- found: medium: Silent failure in _cycle_state_write_iter_start: if the locked state write fails (disk full, lock timeout), the state file keeps the stale current_iter from the previous completed iteration, a subsequent resume starts at the wrong iteration, and no warn/log message surfaces why. (core/pipeline/cycle-orchestrator.sh:2478) (and 1 more)

- medium: Silent failure in _cycle_state_write_iter_start: if the locked state write fails (disk full, lock timeout), the state file keeps the stale current_iter from the previous completed iteration, a subsequent resume starts at the wrong iteration, and no warn/log message surfaces why. (core/pipeline/cycle-orchestrator.sh:2478)
- low: When both --resume and --from-stage are active, _runner_resume_rehydrate (line 2946) and _runner_from_stage_preflight (line 3036) each call _artifact_persist_restore independently, performing two redundant git checkout operations against the state branch; no-clobber prevents corruption but the double I/O is unnecessary. (core/pipeline/runner.sh:2946)
- score: 8
