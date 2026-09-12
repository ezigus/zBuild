## File
`core/plugin-registry/requires-core.sh` — `requires_core_check` enforces ADR-004: agent plugins MUST declare `redaction` inside `requires.core`. Removing this check causes agent plugins without the redaction chokepoint to silently pass validation, defeating the safety invariant.

The rule lived in `validate_manifest` (`core/plugin-registry/manifest-validation.sh`) until #2065, which SUBSUMED the hardcoded string check into the resolver rather than leaving the two side by side. The check did not change; it moved, and the variable it reads is now `$declared`. This spec follows it, exactly as `registry-validate-manifest-mutations.md` did.

> **Known overlap, pre-existing — for the maintainer, not for this spec to resolve.** On `origin/main` this spec and `registry-validate-manifest-mutations.md` apply the *identical* mutation (same anchor line, same `if false;` replacement differing only by a trailing comment) and name the *identical* expected failing test. The duplication predates #2065 and is untouched by it; the filename suggests this spec once covered role resolution and drifted. Both are retargeted so neither goes inert, but one of them is redundant coverage.

## Mutation
Remove the ADR-004 redaction enforcement block from `requires_core_check` so that agent plugins whose `requires.core` list omits `redaction` are accepted instead of rejected with rc=1.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/plugin-registry/requires-core.sh")
src = p.read_text()
# Neutralise the redaction check: replace the failing branch with a no-op return
new = src.replace(
    'if ! grep -Fxq "redaction" <<< "$declared"; then',
    'if false; then  # mutation: ADR-004 redaction check disabled',
    1,
)
assert new != src, "patch did not match the redaction grep guard"
p.write_text(new)
PY
```

## Expected failing test
`tests/integration/core-plugin-registry-test.sh` — the test asserts `validate_manifest` returns rc=1 for an agent manifest that lacks `redaction` in `requires.core` (the `bad-no-redaction` fixture). With the mutation, `validate_manifest` returns rc=0 for that fixture and the `assert_eq` on rc=1 fails.

`tests/unit/requires-core-resolution-test.sh` — SPEC-10 asserts the same rule directly against `requires_core_check`, so it fails too.

## Test
```bash
bash tests/integration/core-plugin-registry-test.sh
bash tests/unit/requires-core-resolution-test.sh
```

## Result
The mutation is caught: the registry integration test fails at the assertion `validate_manifest rejects agent without redaction in requires.core (ADR-004 enforcement)` because the mutated code accepts the bad-no-redaction fixture instead of rejecting it, and SPEC-10 fails alongside it.
