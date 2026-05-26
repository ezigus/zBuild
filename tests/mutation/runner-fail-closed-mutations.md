## File
`core/pipeline/runner.sh`

## Mutation
Suppress the `pipeline.abort` event emission in `_runner_abort_trap` by replacing the `eb_emit_event "pipeline.abort"` call with `true`. The `if ! ...; then` structure stays valid bash; `true` returns 0 so the `if !` branch never fires, but no event is emitted.

(The deeper fail-open regression — `|| true` on `_set_pipeline_status` — targets a state-write failure path the existing tests don't exercise; tracking that coverage gap separately as #300.)

## Patch
```bash
sed -i.mutbak 's|eb_emit_event "pipeline.abort"|true|' core/pipeline/runner.sh
```

## Expected failing test
`tests/integration/core-pipeline-runner-test.sh` — Test A2 asserts that exactly one `pipeline.abort` event is emitted when a running pipeline is killed (line ~361).

## Test
```bash
bash tests/integration/core-pipeline-runner-test.sh
```

## Result
The mutation is caught: Test A2 fails because no `pipeline.abort` event lands in `events.jsonl` after the kill.
