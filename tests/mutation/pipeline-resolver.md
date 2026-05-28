## File
`core/pipeline/resolver.sh` — `resolve_plugin_for_role` resolves a role + platform pair to the best-matching plugin directory. A broken resolver causes the wrong plugin (or no plugin) to run for a stage, corrupting the pipeline.

## Mutation
Swap the platform-match priority so generic candidates are tried first (before platform-specific candidates). Replace `candidates_platform` with `candidates_generic` in the primary result selection block, causing platform-specific plugins to be silently skipped in favour of generic fallbacks even when an exact platform match exists.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/pipeline/resolver.sh")
src = p.read_text()
new = src.replace(
    'if [[ ${#candidates_platform[@]} -gt 0 ]]; then\n        result="$(_resolver_pick_best "${candidates_platform[@]}")"\n    elif [[ ${#candidates_generic[@]} -gt 0 ]]; then\n        result="$(_resolver_pick_best "${candidates_generic[@]}")"',
    'if [[ ${#candidates_generic[@]} -gt 0 ]]; then\n        result="$(_resolver_pick_best "${candidates_generic[@]}")"\n    elif [[ ${#candidates_platform[@]} -gt 0 ]]; then\n        result="$(_resolver_pick_best "${candidates_platform[@]}")"',
    1,
)
assert new != src, "patch did not match the platform/generic priority block"
p.write_text(new)
PY
```

## Expected failing test
`tests/unit/core-pipeline-resolver-test.sh` — asserts that a platform-specific plugin wins over a generic plugin when both match the requested role and the platform is supplied. With the mutation the generic plugin is returned instead, causing the `assert_eq` on the returned plugin directory to fail.

## Test
```bash
bash tests/unit/core-pipeline-resolver-test.sh
```

## Result
The mutation is caught: the resolver test fails because the platform-specific candidate is no longer preferred; the generic plugin is returned where the platform-specific one was expected.
