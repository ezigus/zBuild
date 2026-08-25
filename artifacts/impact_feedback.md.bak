## Scope gaps found — three files missing

### 1. `tests/unit/test-plugin-result-write-fallback-test.sh` (step-2)

This test sources `plugins/tool/test/plugin.sh` and calls `_test_write_result` directly, then asserts several top-level field paths that step-2 moves under `data:{}`:

| Line | Assertion | Field moving to |
|------|-----------|----------------|
| 73 | `jq -r '.passed'` | `data.passed` |
| 83 | `jq -r '.failed'` | `data.failed` |
| 106 | `jq -r '.test_cmd'` | `data.test_cmd` |
| 117 | `jq -r '.diff_applied'` | `data.diff_applied` |
| 128 | `jq -r '.exit_code'` | `data.exit_code` |
| 138-141 | `.verdict`, `.exit_code`, `.passed`, `.diff_applied` | verdict stays top-level; others move to data |

All data-field assertions must be updated to read from `.data.*`.

### 2. `tests/unit/readout-gates-test.sh` (step-2)

`_seed_results()` at line 46 writes `jq -n "$block" > test-results.json`, and every lint/coverage/mutation test case passes a top-level block like `'{lint:{status:"pass",...}}'`. After step-2 updates `lint-gate`, `coverage-gate`, and `mutation-gate` to read `.data.lint`, `.data.coverage`, `.data.mutation`, these fixtures must be reseeded as `{data:{lint:{...}}}`. Without this change, every L1–M6 assertion in the file fails silently (returns `skip` instead of the expected `pass`/`fail`).

### 3. `tests/integration/build-test-cycle-targeted-rerun-test.sh` (step-2)

Line 102 reads `.run_mode // "?"` from the live test plugin's `test-results.json` output:
```bash
local rm; rm="$(jq -r '.run_mode // "?"' "$ad/test-results.json" 2>/dev/null || echo "?")"
```
Line 123 then asserts `"targeted"`. After step-2 moves `run_mode` under `data`, the top-level path silently returns `null`, the `// "?"` fallback fires, `iter2_mode` becomes `"?"`, and the assertion fails. The jq path must be updated to `.data.run_mode // "?"`.
