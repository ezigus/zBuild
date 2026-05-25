## File
`core/pipeline/runner.sh`

## Mutation
Flip a load-bearing `||` (fail-closed) back to `|| true` (fail-open) in the `_runner_abort_trap` function — specifically the `_set_pipeline_status` call that marks the pipeline as `interrupted` on abort. This means a killed pipeline would never record its interrupted state.

## Expected failing test
`tests/integration/core-pipeline-runner-test.sh` (Test A2) — asserts that after a SIGKILL the pipeline state is `interrupted`. With this mutation the state remains `in_progress` and the assertion fails.

## Result
The mutation is caught: Test A2 fails because the pipeline state file does not transition to `interrupted` after the process is killed.
