## File
`core/memory/contract.sh` — `memory_has_capability` reports whether the loaded backend declares a given capability string. Inverting its return code causes callers to see absent capabilities as present and vice versa, breaking any test that verifies capability detection.

## Mutation
Flip the final return values in `memory_has_capability`: return 0 when the capability is NOT found and return 1 when it IS found. This inverts the capability contract.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/memory/contract.sh")
src = p.read_text()
# Swap the grep-success path (return 0) and the fallback (return 1)
new = src.replace(
    '    if printf \'%s\' "$caps" | grep -qF "${cap}" 2>/dev/null; then\n        return 0\n    fi\n    return 1\n}',
    '    if printf \'%s\' "$caps" | grep -qF "${cap}" 2>/dev/null; then\n        return 1\n    fi\n    return 0\n}',
    1,
)
assert new != src, "patch did not match capability return block"
p.write_text(new)
PY
```

## Expected failing test
`tests/unit/core-memory-contract-test.sh` — asserts `assert_exit_code "memory_has_capability text_search returns 0" "0" "$cap_rc"`. With the mutation, `memory_has_capability text_search` returns 1 (found → inverted), and the exit-code assertion fails.

## Test
```bash
bash tests/unit/core-memory-contract-test.sh
```

## Result
The mutation is caught: the memory contract test fails at `assert_exit_code "memory_has_capability text_search returns 0"` because the mutated function returns 1 instead of 0 for a declared capability.
