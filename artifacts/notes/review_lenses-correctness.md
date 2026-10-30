# Correctness lens notes — issue #1760

## Files read
- core/pipeline/cycle-orchestrator.sh (full _cycle_load_template, _cycle_eval_one_condition, _cycle_check_until, _cycle_check_abort_when)
- core/pipeline/template.sh (_tpl_validate_cycles lines 1120-1265)
- tests/unit/template-loader-recursive-flow-test.sh (SPEC-1/2/3/9 tests)
- tests/unit/core-pipeline-cycle-events-test.sh (SPEC-7/8 tests)
- tests/integration/cycle-orchestrator-abort-when-test.sh (SPEC-6 tests)
- tests/integration/cycle-abort-when-no-match-converges-test.sh (SPEC-4/5 tests)

## Conclusions

### Finding 1: `ne` retained in `ne|neq` in all three evaluators (INTRODUCED)
All three evaluators (_cycle_eval_one_condition line 478, _cycle_check_until line 564,
_cycle_check_abort_when line 808) use `ne|neq` pattern. The design decision says to
"rename `ne` to `neq`" (not add alongside). `ne` is refused at load via _tpl_validate_cycles,
but if it reaches an evaluator (test-only mode or direct invocation), it silently evaluates
via the `ne|neq` branch, bypassing `*)`. This violates R3 (ne refused) and R4's spirit
(a refused op should not silently evaluate). Severity: medium.

### Finding 2: Numeric op early return skips predicate emit AND stash in _cycle_check_until single-condition (INTRODUCED)
At _cycle_check_until lines 565-568: when gt/gte/lt/lte encounters non-numeric operands,
`return 1` fires before `_cycle_emit_predicate` (line 584) and `_cycle_stash_predicate` (line 587).
So no predicate event is emitted for this iteration, and the stash retains the prior
evaluation's data. Same pattern in _cycle_eval_one_condition (missing emit only; multi-condition
outer code stashes unconditionally) and in _cycle_check_abort_when (abort_when only stashes on match).
Severity: low (error path; an error was already emitted).

### Finding 3: `until.op` validation gated on non-empty check in _tpl_validate_cycles (PRE-EXISTING)
template.sh line 1242: `if [[ -n "$uo" ]]`. A template with missing until.op passes
load validation, and fails at runtime with generic "until.{stage,field,op,value} all required".
SPEC-2 tests an invalid op, not a missing one — this gap is outside the strict issue scope
but is a partial SPEC-2 edge case. Same applies to abort_when.op (line 1255). Not introduced.

### Finding 4: `max_iterations` optional in _cycle_load_template changes error class (INTRODUCED)
Old code: missing max_iterations → cycle.config.invalid at load. New code: _cycle_load_template
skips validation when max_iterations is absent (lines 359-373). If somehow a production cycle
runs without max (bypassing _tpl_validate_cycles), _cycle_check_max_iterations emits
cycle.metric.invalid and terminates immediately, replacing the diagnostic-rich config.invalid.
Severity: low (fail-closed, but weaker diagnostic path).

### Finding 5: Multi-condition exit_when field/stage validation removed from _cycle_load_template (INTRODUCED)
The change removes ew_f (verdict|status) validation and ew_s stage-membership check from
_cycle_load_template's multi-condition loop (lines 334-346 in the diff, removed entirely).
Single-condition still has field check at lines 397-404 — asymmetry. The runtime check is now
absent for multi-condition. The comment says _tpl_validate_cycles handles it, which is true
for template load paths but not for direct _cycle_load_template invocations. Severity: low
(intentional per design comment, protected at load time by _tpl_validate_cycles).

## SPEC coverage assessment

- SPEC-1 (abort_when.op at load): delivered ✓ template.sh:1252-1261
- SPEC-2 (until.op at load): delivered for non-empty op ✓; missing op gap (pre-existing)
- SPEC-3 (multi exit_when op at load): delivered ✓ template.sh:1210-1212
- SPEC-4 (eight ops in _cycle_check_until): delivered ✓ lines 562-589
- SPEC-5 (eight ops in _cycle_eval_one_condition): delivered ✓ lines 476-499
- SPEC-6 (eight ops in _cycle_check_abort_when): delivered ✓ lines 806-827
- SPEC-7 (numeric op non-numeric error): delivered ✓; stash/emit skipped on error (finding 2)
- SPEC-8 (*) branch): delivered ✓ (but ne bypasses it via ne|neq, finding 1)
- SPEC-9 (ADR update, baseline removal): delivered ✓

## Score rationale
All nine SPECs are substantially delivered. Two medium-impact issues introduced:
ne retained in evaluators (R3/R4 violation, no production impact since load blocks ne);
numeric error early return skips predicate observability. Two low-impact changes in
_cycle_load_template behavior (optional max, removed multi-condition runtime checks).
Score: 6/10
