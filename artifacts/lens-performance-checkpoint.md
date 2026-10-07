# Performance lens checkpoint

## Files read
- diff.patch: full diff in context (advisory-section.sh, manifest.yaml, plugin.sh, pr-open-test.sh)

## Analysis in progress

### plugin.sh changes (around line 130+)
Three separate `jq` process spawns on the same `state_file`:
1. `.status` → `_state_status`
2. `[.cycle_iterations ... | select(.value.status == "max_iterations")] | length` → `_max_iter_count`
3. `[.cycle_iterations ... | select(.value.status == "max_iterations") | {...}]` → `_convergence_json`

Calls 2 and 3 traverse `cycle_iterations` with the same filter. `_max_iter_count` is only used for `> 0`, but `_convergence_json != "[]"` already implies that. Redundant traversal + extra process spawn.

### advisory-section.sh changes
`_pr_open_render_gate_section` makes three `jq` calls on the same `gate_path`:
1. `.verdict`
2. `.failed // [] | join(", ")`
3. `.reason`

All three could be one `jq` call.

## Conclusions
- Not a hot path: PR opens happen once per run
- All issues are low severity (process-spawn overhead, not O(n²))
- Introduced by this change: yes

## What is still unresolved
- Nothing material — analysis complete enough for findings
