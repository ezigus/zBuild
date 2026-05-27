## File
`core/pipeline/dispatch.sh` — when sourced standalone (e.g. by a unit test that doesn't pre-load the registry), dispatch.sh must self-source `core/plugin-registry/registry.sh` so `yaml_get` and `discover_plugins` are defined. Without this, the function silently iterates an empty stream and always returns rc=1.

## Mutation
Stub out the self-source: replace the `source registry.sh` call with `:` (no-op).

## Patch
```bash
sed -i.mutbak 's|source "$_ZBUILD_DISPATCH_ROOT/core/plugin-registry/registry.sh"|:|' core/pipeline/dispatch.sh
```

## Expected failing test
`tests/unit/core-pipeline-dispatch-test.sh` — Section 1 asserts `yaml_get` and `discover_plugins` are defined after sourcing dispatch.sh alone (no prior registry load). Section 2's happy-path lookups also break because `discover_plugins` is undefined.

## Test
```bash
bash tests/unit/core-pipeline-dispatch-test.sh
```

## Result
The mutation is caught: Section 1 fails (`yaml_get` / `discover_plugins` missing), and the test exits non-zero.
