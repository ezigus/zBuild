## File
`core/plugin-registry/registry.sh`

## Mutation
Disable the `kind: agent ⇒ requires.core: [redaction]` guard in `validate_manifest`. Replace the structural list-membership check with `if false`, so an agent plugin without `redaction` in `requires.core` silently passes validation.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/plugin-registry/registry.sh")
src = p.read_text()
new = src.replace(
    'if ! grep -Fxq "redaction" <<< "$core_items"; then',
    'if false; then',
    1,
)
assert new != src, "patch did not match the redaction membership gate"
p.write_text(new)
PY
```

## Expected failing test
`tests/integration/core-plugin-registry-test.sh` — asserts that a `kind: agent` manifest without `requires.core: [redaction]` is rejected by `validate_manifest`.

## Test
```bash
bash tests/integration/core-plugin-registry-test.sh
```

## Result
The mutation is caught: the registry test fails because an invalid manifest (no redaction declaration) silently passes validation.
