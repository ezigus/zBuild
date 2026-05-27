## File
`core/pipeline/dispatch.sh` — `_find_plugin_for_stage` resolves stage name → plugin directory via the registry. A misroute = wrong plugin executes for a stage = downstream pipeline corruption.

## Mutation
Invert the id-comparison sense in `_find_plugin_for_stage`: match when `id != stage` instead of `id == stage`. The first non-matching plugin is returned (or, with a single fixture, nothing matches). Either way, every happy-path lookup is wrong.

Companion mutations covering the same file live in `pipeline-dispatch-failopen-mutations.md`, `pipeline-dispatch-arg-mutations.md`, `pipeline-dispatch-selfsource-mutations.md`, and `pipeline-dispatch-prefix-mutations.md` — split per the harness's one-mutation-per-file model (`scripts/run-mutation.sh`).

## Patch
```bash
sed -i.mutbak 's|\[\[ "$id" == "$stage" \]\]|[[ "$id" != "$stage" ]]|' core/pipeline/dispatch.sh
```

## Expected failing test
`tests/unit/core-pipeline-dispatch-test.sh` — Section 2 ("happy-path stage→plugin resolution") asserts the returned directory contains the queried stage's id. With the inversion, the returned dir belongs to a different plugin (or no plugin matches → rc=1), so multiple `assert_eq` / `assert_contains` calls fail.

## Test
```bash
bash tests/unit/core-pipeline-dispatch-test.sh
```

## Result
The mutation is caught: the unit test exits non-zero. Section 2's `assert_contains "returned dir contains plugin id 'intake'"` fails because the function either returned a different plugin's dir or rc=1, and Section 7's exact-match guards (`rc=1 for prefix-only id 'intak'`) also flip to rc=0 because every non-equal id now matches.
