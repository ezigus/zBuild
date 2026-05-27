## File
`core/pipeline/dispatch.sh` — `_find_plugin_for_stage <stage> [plugins_root]`. The explicit `$2` argument must override `$ZBUILD_PLUGINS_ROOT`; the runner relies on this for test fixtures and worktree-scoped pipelines.

## Mutation
Drop the `$2` arg precedence — always honor the env var. Callers passing an explicit alternate plugins_root will silently search the wrong tree.

## Patch
```bash
sed -i.mutbak 's|plugins_root="${2:-${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_DISPATCH_ROOT/plugins}}"|plugins_root="${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_DISPATCH_ROOT/plugins}"|' core/pipeline/dispatch.sh
```

## Expected failing test
`tests/unit/core-pipeline-dispatch-test.sh` — Section 4 ("explicit plugins_root arg wins over env") creates a plugin under an alt-root and asserts `_find_plugin_for_stage "special" "$alt_root"` returns rc=0 with the alt-root path. With the mutation, `$2` is ignored and the lookup misses.

## Test
```bash
bash tests/unit/core-pipeline-dispatch-test.sh
```

## Result
The mutation is caught: `assert_eq "rc=0 when stage matches plugin in explicit plugins_root" "0" "$rc"` fails (returns rc=1 because the env root has no 'special' plugin). Test exits non-zero.
