# Performance lens notes — Issue #1760

## Files examined
- core/pipeline/cycle-orchestrator.sh (full diff + surrounding context)
- core/pipeline/template.sh (_tpl_validate_cycles around lines 1190-1265)

## Key facts
- `_CYCLE_ABSOLUTE_MAX = 10` (line 73): max cycle iterations is a hard constant of 10.
- `_cycle_load_template` is called ONCE per cycle execution (line 2208).
- `_cycle_check_until` called ONCE per iteration (line 2377).
- `_cycle_check_abort_when` called ONCE per iteration (line 2484).
- `_cycle_eval_one_condition` called ONCE per condition per iteration (multi-condition path).

## Algorithmic complexity analysis

### No O(n^2) regression introduced
- Old `_cycle_load_template` did O(conditions × stages) linear scan (stage membership check per condition). Removed in this change — improvement.
- `_tpl_validate_cycles` retains O(conditions × stages) check, but runs only once at template load, not per run.
- All three evaluators are O(1) per call — case dispatch is constant time.

### Numeric op: double regex per iteration (introduced)
For `gt|gte|lt|lte`, each evaluator does:
```bash
if ! [[ "$actual" =~ ^-?[0-9]+$ ]] || ! [[ "$expected" =~ ^-?[0-9]+$ ]]; then
```
`expected` is a template constant (set once at load) but re-validated on EVERY iteration.
With `_CYCLE_ABSOLUTE_MAX=10`, at most 10 redundant checks per cycle. Negligible in practice.

### `matches` op: uncached regex per iteration (introduced)
`[[ "$actual" =~ $expected ]]` re-evaluates the regex pattern from scratch on each iteration.
Bash does not cache compiled ERE across `=~` invocations. Pattern is a template constant.
Over 10 iterations, trivial overhead. No O(n^2) concern.

### Nested case for numeric ops (introduced)
Outer case dispatches to `gt|gte|lt|lte` group, then inner case re-dispatches to specific op.
Two case dispatches instead of one. O(1), per-iteration overhead is constant and minimal.

### `ne|neq` dead code in evaluators
All three evaluators accept `ne` at runtime (`ne|neq)` arm), but `_tpl_validate_cycles`
refuses `ne` at template load. The `ne` pattern is an unreachable match arm in the hot path.
No runtime cost beyond the case pattern scan (constant), but it's dead code after this change.

### Removed validation in `_cycle_load_template`
Old: validated field (verdict|status), op (eq|ne), and stage membership per condition at cycle start.
New: entirely removed from `_cycle_load_template`; relies on `_tpl_validate_cycles` at template load.
This is a load-time improvement, not a regression.

## Conclusion
No O(n^2) or blocking-I/O regressions introduced. Two minor hot-path observations:
1. `expected` numeric type check redundantly runs per iteration rather than once at cycle start.
2. `matches` regex re-compiled from scratch each iteration (pattern is constant).
Both are bounded by `_CYCLE_ABSOLUTE_MAX=10`. Score: 9/10.
