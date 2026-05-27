## File
`core/pipeline/dispatch.sh` — `_find_plugin_for_stage` must return `rc=1` when no plugin's id matches the requested stage. Fail-open here would let a missing plugin look like a found one.

## Mutation
Replace the trailing `return 1` in `_find_plugin_for_stage` with `return 0` — fail-open on "plugin not found".

## Patch
```bash
sed -i.mutbak '/^_find_plugin_for_stage()/,/^}/ s|    return 1$|    return 0|' core/pipeline/dispatch.sh
```

## Expected failing test
`tests/unit/core-pipeline-dispatch-test.sh` — Section 3 ("not-found returns rc=1") and Section 5 ("empty / missing plugins_root") each assert `assert_eq ... "1" "$rc"`. With the mutation, `rc=0` on every miss.

## Test
```bash
bash tests/unit/core-pipeline-dispatch-test.sh
```

## Result
The mutation is caught: multiple `assert_eq "rc=1 ..." "1" "$rc"` calls in Sections 3 and 5 report `expected: 1, got: 0`, and the unit test exits non-zero.
