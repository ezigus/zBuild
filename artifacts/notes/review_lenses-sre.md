# SRE Review: Issue #1760 — cycle-orchestrator op validation

## Files examined
- core/pipeline/cycle-orchestrator.sh (lines 280-428, 459-838, 2123-2398)
- core/pipeline/template.sh (lines 1100-1265)
- tests/unit/template-loader-recursive-flow-test.sh
- tests/integration/cycle-orchestrator-abort-when-test.sh
- tests/integration/cycle-abort-when-no-match-converges-test.sh
- tests/unit/core-pipeline-cycle-events-test.sh

---

## Failure Modes / Blast Radius

### 1. Empty _CYCLE_STAGES — silent no-op at load, potential iterator-range issue at runtime
_cycle_load_template now makes stages_csv entirely optional (lines 351-357).
If a production run arrives with an empty stages_csv (bug in template parser, not caught by _tpl_validate_cycles), _CYCLE_STAGES=() is set silently with NO error, NO cycle.config.invalid event.
Downstream: cycle_orchestrator_run at line 2232 does `for (( iter=1; iter <= _CYCLE_MAX_ITER; iter++ ))`.
If _CYCLE_MAX_ITER is also empty (also optional now), the `for` loop guard `-le` would compare against empty string.
Actually: `_CYCLE_MAX_ITER` is populated only from `${!max_var:-}` (line 359), so an empty max is left empty; the `for` condition `iter <= ""` evaluates as numeric 0 in bash arithmetic, so `1 <= 0` is false → the loop body never runs. The cycle silently returns rc=0 (converged) without running any stages. This is a silent no-op failure.

Actually looking more carefully: `for (( iter=1; iter <= _CYCLE_MAX_ITER; iter++ ))` — if `_CYCLE_MAX_ITER=""`, bash arithmetic treats empty as 0, so `1 <= 0` is false, loop never runs. BUT `_cycle_state_init` is called before the loop (line 2218) with `$_CYCLE_MAX_ITER` which is empty, and it does `jq --argjson max "$_ZB_CYCLE_MAX"` — an empty argjson would cause jq to fail. So if stages AND max are both empty, _cycle_state_init likely fails and the early-exit path at line 2221 fires. That returns rc=1. Not a silent no-op.

If only stages are empty but max is set (which is the more likely partial-invalid case), the for-loop runs but `for s in "${_CYCLE_STAGES[@]}"` iterates zero members → _cycle_iter_dispatch returns success with an empty blob → cycle appears to converge without dispatching anything. This is masked convergence.

The comment says "_tpl_validate_cycles guarantees they are present before any production run." That guarantee holds only if _tpl_validate_cycles is always called before cycle_orchestrator_run. If _cycle_load_template is called directly by tests with only condition vars set, this is intentional and test-only. The comment makes this explicit. Risk is LOW for production because _tpl_validate_cycles enforces stages presence.

### 2. ne alias in evaluators vs. neq-only in _tpl_validate_cycles
template.sh _tpl_validate_cycles (line 1210-1213) rejects `ne` — only `neq` is in the eight-op set.
cycle-orchestrator.sh evaluators handle `ne|neq` (lines 477, 564, 807).

Gap: If a template var is set externally (bypassing load_template) with op=`ne`, it passes _cycle_load_template (which does NOT re-validate op, line 406: "until.op: validated at template load time; not re-validated here.") and reaches the evaluator. In that case `ne` works fine because the `ne|neq` case handles it.

But load_template DOES call _tpl_validate_cycles which rejects `ne`, so any properly loaded template with op=ne fails at load. The ne|neq alias in evaluators is defence-in-depth for tests that bypass load_template (and for backward compat with pre-#1760 templates that used `ne`). 

Production path: templates using `ne` will be REJECTED at load. This is a potentially breaking change for existing templates using `ne` op. However, pre-#1760 code only accepted `ne` in a narrower multi-condition path (old `eq|ne|in` set), so `ne` was only legal there before. Templates that previously used `ne` in multi-condition exit_when would now fail at load with the new stricter `neq`-only set. This is the rollback concern: no migration path for `ne` op.

### 3. until.op validation: empty op silently passes at template.sh
template.sh lines 1241-1248:
```
local uo="${!uo_var:-}"
if [[ -n "$uo" ]]; then
    case "$uo" in
        eq|neq|gt|gte|lt|lte|contains|matches) : ;;
        *) error ...; return 1 ;;
    esac
fi
```
The `if [[ -n "$uo" ]]` guard means an ABSENT/empty until.op passes silently. But immediately below in _cycle_load_template (line 390-394), an empty until.op causes "until.{stage,field,op,value} all required" → error. So the empty-op case causes a load failure, just with a less specific error message. It does NOT reach the runtime evaluator. Risk is low but the error message when op is empty is less specific than when it is invalid.

### 4. matches op: unquoted ERE
Line 492 and 577 in cycle-orchestrator.sh:
```bash
matches)  [[ "$actual" =~ $expected ]] && { _match="true"; _rc=0; } ;;
```
`$expected` is intentionally unquoted (required for bash ERE), but this means a regex with special characters (e.g., `[abc`) could cause a `[[` parse error and abort the evaluation with rc=2, not rc=1. Under set +e this just leaves _rc=1 (no match), which is the safe-fail direction. However the error is not logged; the evaluator silently returns 1 (no-match / false negative). This is an observability gap.

Also: if $expected contains a glob character, bash could treat it as a filename glob in some edge cases. The `=~` operator in bash [[ ]] is safe from word-splitting but an invalid regex causes the [[ ]] to fail with rc=2.

### 5. Numeric guard: integer-only, no floats, leading zeros
The regex `^-?[0-9]+$` (lines 480, 566, 810) rejects:
- floats (3.14) — silently returns rc=1 with error message, good
- leading zeros (010) — accepted; bash interprets `010` as decimal 10 in (( )) arithmetic, not as octal. This is consistent but could surprise if the template author expected octal.
- scientific notation (1e5) — rejected (correct)

Low risk since these are CI/build verdicts, not arbitrary numbers.

---

## Observability / Missing Events

### 6. No cycle.config.invalid when stages/max silently absent (test-only mode bypass)
Old behavior: no stages → cycle.config.invalid reason=no_stages (from _cycle_load_template).
New behavior: no stages → silently skips, no event emitted.
If a production run somehow reaches _cycle_load_template with empty stages (parser bug), the omission is invisible in the event stream. _tpl_validate_cycles does emit an error for missing stages, so this gap only matters if _tpl_validate_cycles is bypassed.

### 7. *) branch in evaluators: only `error` call, no _cycle_emit
Lines 493-495, 579-581, 823-825:
```
*)
    error "cycle exit_when: unrecognized op '$op'"
    return 1
    ;;
```
The `error` function writes to stderr. There is NO `_cycle_emit` call, so the unrecognized-op event is NOT written to events.jsonl (ZBUILD_EVENTS_JSONL). Operators monitoring the event stream would not see this failure. The load-time validation is supposed to prevent reaching this, but if it is reached (test bypass, external var injection), it is invisible to structured telemetry.

### 8. abort_when.op validation at template.sh emits only error, no event
template.sh lines 1255-1261: when abort_when op is invalid, only `error` is called (which goes to stderr). No _cycle_emit or event. This is at template load time where the orchestrator is not yet running, so no cycle.config.invalid event is emitted. Inconsistent with the runtime pattern where _cycle_load_template emits cycle.config.invalid for other validation failures. However, _tpl_validate_cycles is a static validation step — it intentionally does not emit events (it is not the orchestrator). This is consistent with how other _tpl_validate_* functions work.

---

## SLO Impact

### 9. Breaking change: templates using previously-silently-ignored invalid ops now hard-fail at load
Before this change: an unknown abort_when.op (e.g., `contains_all`) was silently accepted at load and then silently never matched at runtime → cycle ran to max_iterations.
After: same template fails at load → cycle returns rc=4 (config_invalid) immediately.

Impact: Any template in the field using a non-standard op in abort_when, until, or multi-condition exit_when will go from "runs to max_iterations" to "hard-fails at load". For templates using only `eq` (the only previously-valid op), this is a no-op. For templates that somehow had invalid ops (silent typos), this is a hard-fail blast on upgrade.

### 10. ne → neq rename: no migration path
The old multi-condition exit_when accepted `ne` as a valid op. The new code refuses `ne` at template load (only `neq` in the eight-op set). Templates using `ne` in multi-condition exit_when will now fail at load. No deprecation warning, no alias at the template/load level. The evaluator accepts `ne|neq` at runtime but the validator refuses `ne` at load.

---

## Graceful Degradation

### 11. Defense-in-depth *) branch covers bypass scenarios
If _tpl_validate_cycles is bypassed (e.g., _cycle_load_template called directly with template vars set manually), the *) branch in each evaluator fires, calls `error`, and returns 1. This means:
- For exit_when: the condition never matches → cycle runs to max_iterations (safe, not premature convergence)
- For abort_when: abort_when never fires → cycle runs to max_iterations (safe, not spurious abort)
- For exit_when numeric ops with non-numeric values: error + return 1 → no silent false convergence

This is the correct fail-safe direction.

---

## Rollback

### 12. Rollback path exists but has caveats
Rolling back removes the new op validation and the new evaluator ops. Effect:
- Templates that now fail at load (invalid ops) would go back to silently running to max_iterations — safe behavior restored.
- Templates that use new ops (gt/gte/lt/lte/contains/matches) in their conditions would evaluate as unrecognized → run to max_iterations rather than converging correctly (the `ne` alias would also stop working in the old single-condition path where ne was not supported).
- Rollback is technically clean; no state corruption risk.

---

## Summary Score Rationale
- No crash risk for production runs using the standard `eq` op
- The silent no-ops for empty stages/max only matter if _tpl_validate_cycles is bypassed, which is prohibited in production
- The `ne` → `neq` rename is a potential breaking change for existing templates using `ne` in multi-condition exit_when
- The *) branch lacks structured event emission (observability gap)
- The matches regex can silently fail on invalid patterns
- Overall: change is additive/correct for the standard case; the breaking change for `ne` op and the missing structured event for *) are the main concerns

