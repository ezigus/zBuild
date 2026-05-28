## File
`plugins/tool/memory-sqlite/plugin.sh` — `memory_backend_init` returns rc=2 (hard/unrecoverable) when sqlite3 is missing. Weakening this to rc=1 (soft/retryable) violates ADR-001: a missing binary is not transient; retrying would never succeed.

## Mutation
In `memory_backend_init`, change the `return 2` on the "sqlite3 not found" path back to `return 1`, simulating a developer who forgets the ADR-001 distinction between soft and hard failure.

## Patch
```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path("plugins/tool/memory-sqlite/plugin.sh")
src = p.read_text()
old = '        warn "memory-sqlite: sqlite3 not found; memory operations will fail" >&2 || true\n        return 2'
new = '        warn "memory-sqlite: sqlite3 not found; memory operations will fail" >&2 || true\n        return 1'
assert old in src, f"patch target not found in plugin.sh; found:\n{src[src.find('sqlite3 not found'):src.find('sqlite3 not found')+200]!r}"
p.write_text(src.replace(old, new, 1))
PY
```

## Expected failing test
`tests/unit/plugin-memory-sqlite-rc-test.sh` — Test 1 asserts that `memory_backend_init` returns rc=2 when sqlite3 is absent. With the mutation, the function returns rc=1 instead of rc=2, and the assertion `[[ "$rc" -eq 2 ]]` fails.

## Test
```bash
bash tests/unit/plugin-memory-sqlite-rc-test.sh
```

## Result
The mutation is caught: Test 1 fails because `memory_backend_init` returns rc=1 (soft) instead of rc=2 (hard/unrecoverable) on the "sqlite3 not found" path, violating ADR-001.
