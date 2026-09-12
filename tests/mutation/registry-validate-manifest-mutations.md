## File
`core/plugin-registry/requires-core.sh`

## Mutation
Disable the `kind: agent ⇒ requires.core: [redaction]` guard. It moved out of
`validate_manifest` into `requires_core_check` in #2065 — the hardcoded
string-membership check there was SUBSUMED by the resolver rather than left
duplicated alongside it — so the mutation now targets the rule in its new home.
Replace the list-membership test with `if false`, so an agent plugin without
`redaction` in `requires.core` silently passes validation.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/plugin-registry/requires-core.sh")
src = p.read_text()
new = src.replace(
    'if ! grep -Fxq "redaction" <<< "$declared"; then',
    'if false; then',
    1,
)
assert new != src, "patch did not match the redaction membership gate"
p.write_text(new)
PY
```

## Expected failing test
`tests/integration/core-plugin-registry-test.sh` — asserts that a `kind: agent` manifest without `requires.core: [redaction]` is rejected by `validate_manifest`.
`tests/unit/requires-core-resolution-test.sh` SPEC-10 asserts the same rule directly, so it fails too.

## Test
```bash
bash tests/integration/core-plugin-registry-test.sh
bash tests/unit/requires-core-resolution-test.sh
```

## Result
The mutation is caught: both tests fail because an invalid manifest (no redaction declaration) silently passes validation.
