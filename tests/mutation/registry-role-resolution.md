## File
`core/plugin-registry/discovery.sh` — `find_plugin_for_role` locates a plugin that provides a given role and backend alias. A broken role lookup causes the wrong plugin to be dispatched (or lookup fails entirely), silently breaking role-based backend selection.

## Mutation
Remove the alias match from `find_plugin_for_role` so only the plugin id is checked and `provides.alias` is never consulted. Replace the compound `||` condition with a strict id-only check, causing any plugin whose id differs from the requested alias (but whose `provides.alias` would have matched) to be skipped.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/plugin-registry/discovery.sh")
src = p.read_text()
new = src.replace(
    'if [[ "$plugin_id" == "$alias" || "$declared_alias" == "$alias" ]]; then',
    'if [[ "$plugin_id" == "$alias" ]]; then',
    1,
)
assert new != src, "patch did not match the alias OR id compound check"
p.write_text(new)
PY
```

## Expected failing test
`tests/integration/core-plugin-registry-test.sh` — asserts that `find_plugin_for_role` resolves a plugin whose `provides.alias` field matches the requested alias even when the plugin id does not. With the mutation, alias-only matches return rc=1 and the test's `assert_eq` on the returned directory fails.

## Test
```bash
bash tests/integration/core-plugin-registry-test.sh
```

## Result
The mutation is caught: the registry integration test fails because a plugin reachable only via its `provides.alias` is no longer found; `find_plugin_for_role` returns 1 where it should return 0 and print the plugin directory.
