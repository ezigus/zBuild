## File
`core/pipeline/runner.sh`

## Mutation
Suppress the `pipeline.abort` event emission in `_runner_abort_trap`. Replace the `eb_emit_event "pipeline.abort" ...` call with a no-op so the operator-visible abort signal vanishes. (The deeper fail-open regression — `|| true` on `_set_pipeline_status` — targets a state-write failure path the existing tests don't exercise; tracking that coverage gap separately.)

## Patch
```bash
sed -i.mutbak 's|if ! eb_emit_event "pipeline.abort"|if ! true \&\& false # MUTATION: suppress emit\nif false # was: eb_emit_event "pipeline.abort"|' core/pipeline/runner.sh
```

## Expected failing test
`tests/integration/core-pipeline-runner-test.sh` — Test A2 asserts that exactly one `pipeline.abort` event is emitted when a running pipeline is killed (line ~361).

## Test
```bash
bash tests/integration/core-pipeline-runner-test.sh
```

## Result
The mutation is caught: Test A2 fails because no `pipeline.abort` event is emitted after the kill.
