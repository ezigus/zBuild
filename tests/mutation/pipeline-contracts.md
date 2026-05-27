## File
`core/pipeline/contracts.sh`

## Mutation
Disable the artifact contract check in `_check_artifact_contract` — replace the
`scan_plugin_outputs` call with `return 0` so the function always reports that
declared outputs are present even when they are missing. This breaks the
fail-closed guarantee that a plugin returning exit 0 but producing no artifact
is treated as a contract violation.

## Patch
```bash
sed -i.mutbak 's|scan_plugin_outputs "\$plugin_dir" "\$state_dir/pipeline-state.json" "\$stage"|return 0  # scan removed by mutation|' core/pipeline/contracts.sh
```

## Expected failing test
`tests/integration/core-pipeline-runner-test.sh` — asserts that a plugin which
exits 0 but does not write its declared output artifact causes the stage to fail
with a `plugin.contract.violated` event. With `_check_artifact_contract` always
returning 0 the stage is incorrectly marked complete and the expected event is
absent.

## Test
```bash
bash tests/integration/core-pipeline-runner-test.sh
```

## Result
The mutation is caught: the pipeline runner integration test fails because the
artifact contract check is suppressed; a plugin that declared an output but
produced nothing is silently accepted, and the `plugin.contract.violated` event
that the test asserts is never emitted.
