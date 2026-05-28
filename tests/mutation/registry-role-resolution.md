## File
`core/plugin-registry/manifest-validation.sh` — `validate_manifest` enforces ADR-004: agent plugins MUST declare `redaction` inside `requires.core`. Removing this check causes agent plugins without the redaction chokepoint to silently pass validation, defeating the safety invariant.

## Mutation
Remove the ADR-004 redaction enforcement block from `validate_manifest` so that agent plugins whose `requires.core` list omits `redaction` are accepted instead of rejected with rc=1.

## Patch
```bash
python3 - <<'PY'
import pathlib, re
p = pathlib.Path("core/plugin-registry/manifest-validation.sh")
src = p.read_text()
# Neutralise the redaction check: replace the failing branch with a no-op return
new = src.replace(
    'if ! grep -Fxq "redaction" <<< "$core_items"; then',
    'if false; then  # mutation: ADR-004 redaction check disabled',
    1,
)
assert new != src, "patch did not match the redaction grep guard"
p.write_text(new)
PY
```

## Expected failing test
`tests/integration/core-plugin-registry-test.sh` — the test asserts `validate_manifest` returns rc=1 for an agent manifest that lacks `redaction` in `requires.core` (the `bad-no-redaction` fixture). With the mutation, `validate_manifest` returns rc=0 for that fixture and the `assert_eq` on rc=1 fails.

## Test
```bash
bash tests/integration/core-plugin-registry-test.sh
```

## Result
The mutation is caught: the registry integration test fails at the assertion `validate_manifest rejects agent without redaction in requires.core (ADR-004 enforcement)` because the mutated code accepts the bad-no-redaction fixture instead of rejecting it.
