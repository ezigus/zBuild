## review-lens-performance — pass

- found: low: In the dispatch-unit loop, `resume_mode` is never cleared after the interrupted stage is found and dispatched, so `get_state_field` (which calls `validate_json` → jq + a second jq field read = 2 subprocesses) fires for every remaining dispatch unit in the loop, even though those subsequent stages cannot be `complete`; for a pipeline with n stages after the interruption point this spawns O(2n) unnecessary jq processes on the hot path. (core/pipeline/runner.sh:3911)

- low: In the dispatch-unit loop, `resume_mode` is never cleared after the interrupted stage is found and dispatched, so `get_state_field` (which calls `validate_json` → jq + a second jq field read = 2 subprocesses) fires for every remaining dispatch unit in the loop, even though those subsequent stages cannot be `complete`; for a pipeline with n stages after the interruption point this spawns O(2n) unnecessary jq processes on the hot path. (core/pipeline/runner.sh:3911)
- score: 8
