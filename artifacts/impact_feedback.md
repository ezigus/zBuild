## Scope gaps — two files still missing (unchanged from prior iter)

Both files flagged in the prior iteration are still missing from the design scope block and still contain the broken references. Verified against the current worktree.

### 1. `tests/unit/readout-gates-test.sh` (step-2)

`_seed_results()` is called at ~15 sites throughout the file and writes top-level JSON blocks:

```bash
_seed_results "$W" '{lint:{status:"pass",exit_code:0,summary:"clean"}}'
_seed_results "$W" '{coverage:{status:"measured",pct:42.5,floor:29}}'
_seed_results "$W" '{mutation:{status:"measured",score:"20/22",floor:15}}'
```

But the gate plugins (already updated in this worktree) now read:
- `lint-gate/plugin.sh:50` — `jq -r '.data.lint.status // empty'`
- `coverage-gate/plugin.sh:66` — `jq -r '[(.data.coverage.status // ""), ...]'`
- `mutation-gate/plugin.sh:56` — `jq -r '[(.data.mutation.status // ""), ...]'`

All L1–L5, C1–C7, and M1–M6 assertions silently produce `skip` (empty path → no match) instead of `pass`/`fail`. The fixtures must be rewritten as `{data:{lint:{...}}}`, `{data:{coverage:{...}}}`, `{data:{mutation:{...}}}`.

### 2. `tests/integration/build-test-cycle-targeted-rerun-test.sh` (step-2)

Line 102:
```bash
local rm; rm="$(jq -r '.run_mode // "?"' "$ad/test-results.json" 2>/dev/null || echo "?")"
```
Line 123:
```bash
assert_eq "T1: iter-2 test stage runs run_mode=targeted (red-set engaged)" "targeted" "$iter2_mode"
```

After the v2 migration moves `run_mode` under `data:{}`, the top-level `.run_mode` path returns null, `// "?"` fires, `iter2_mode` becomes `"?"`, and the assertion fails. Fix: change line 102 to `.data.run_mode // "?"`.

### Note on non-gaps investigated this iter

- `tests/unit/gate-aggregator-test.sh` (lines 197–199, 243–244): writes top-level `test_output` fixtures, but `gate-aggregator/plugin.sh:149` reads `(.data.test_output // .test_output)` — the fallback preserves backward compat, so this file is NOT a gap.
- `tests/unit/core-pipeline-cycle-final-gate-test.sh`: already in scope and already emits v2 format (`result_contract:2`, `data:{run_mode:...}`) at line 32 — no issue.
