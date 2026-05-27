## File
`core/pipeline/dispatch.sh` — stage→plugin id matching must be **exact**. Prefix or substring matching would dispatch the wrong plugin when stage names overlap (e.g. `intake` vs a hypothetical `intake-fast`).

## Mutation
Loosen the exact `[[ "$id" == "$stage" ]]` comparison to a prefix glob `[[ "$id" == "$stage"* ]]`. Now any plugin whose id starts with the queried stage name matches first.

## Patch
```bash
sed -i.mutbak 's|\[\[ "$id" == "$stage" \]\]|[[ "$id" == "$stage"* ]]|' core/pipeline/dispatch.sh
```

## Expected failing test
`tests/unit/core-pipeline-dispatch-test.sh` — Section 7 ("id matching is exact") asserts that querying `"intak"` (prefix of `intake`) returns rc=1. With the mutation, `intake` matches the `intak*` glob, so the lookup wrongly succeeds with rc=0.

## Test
```bash
bash tests/unit/core-pipeline-dispatch-test.sh
```

## Result
The mutation is caught: `assert_eq "rc=1 for prefix-only id 'intak' (not exact)" "1" "$rc"` reports `expected: 1, got: 0`. Test exits non-zero.
