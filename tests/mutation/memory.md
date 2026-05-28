## File
`core/memory/contract.sh` — `memory_has_capability` reports whether the loaded backend declares a given capability string. Inverting its return code causes callers to see absent capabilities as present and vice versa, breaking any test that verifies capability detection.

## Mutation
In `memory_has_capability`, change the `return 0` (capability found → success) to `return 1` so a declared capability appears absent to callers.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("core/memory/contract.sh")
src = p.read_text()
# Target only the grep-success branch return; replace first occurrence of
# the exact line inside memory_has_capability
old = '    if printf \'%s\' "$caps" | grep -qF "\\"${cap}\\"" 2>/dev/null; then\n        return 0\n    fi\n    return 1\n}'
new = '    if printf \'%s\' "$caps" | grep -qF "\\"${cap}\\"" 2>/dev/null; then\n        return 1\n    fi\n    return 0\n}'
assert old in src, f"patch target not found; got: {src[src.find('memory_has_capability'):src.find('memory_has_capability')+400]!r}"
p.write_text(src.replace(old, new, 1))
PY
```

## Expected failing test
`tests/unit/core-memory-contract-test.sh` — asserts `assert_exit_code "memory_has_capability text_search returns 0" "0" "$cap_rc"`. With the mutation, `memory_has_capability text_search` returns 1 (found → inverted to failure), and the exit-code assertion fails.

## Test
```bash
bash tests/unit/core-memory-contract-test.sh
```

## Result
The mutation is caught: the memory contract test fails at `assert_exit_code "memory_has_capability text_search returns 0"` because the mutated function returns 1 instead of 0 for a declared capability.
