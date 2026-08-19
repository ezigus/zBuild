#!/usr/bin/env bash
# Unit (#1887): the disposition response table must DECIDE, not just be logged.
#
# #1822 built the table and #1823 made every dispatch resolve a disposition, but
# nothing consulted it: `disposition_halts`, `disposition_retryable` and
# `disposition_wait_s` had ZERO production callers, and the resolved word reached
# exactly one place — a field on the dispatch event. Retry was still a per-stage
# `router.retries` knob, which is the divergence #1749 was closed to end and the
# reason #1727 had to add that knob to plan's manifest by hand.
#
# These SPECs pin the wiring, not the table (core-pipeline-disposition-test.sh
# owns the table).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "dispatch wiring — the disposition table decides (#1887)"
setup_test_env "dispatch-disposition-wiring"

RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# ─── SPEC-1: the table has production callers on the dispatch path ───────────
# Derived from the source, because the defect WAS "defined but never called" —
# a test that only exercised the table would have passed throughout #1887's life.
print_test_section "SPEC-1: disposition_halts / _retryable / _wait_s are called in dispatch"

for _fn in disposition_halts disposition_retryable disposition_wait_s; do
    # Count real call sites: the function name followed by a quoted argument,
    # excluding comment lines. A mention in prose is not a caller.
    #
    # Captured and counted WITHOUT a pipe. The first cut used
    # `grep ... | grep -v ... | wc -l`, and when grep matched nothing it exited
    # 1, pipefail propagated it, and `set -e` aborted the test before it could
    # report — so the ablation printed nothing instead of failing. That is the
    # #1886 class biting the test that was meant to catch a different one.
    _hits="$(grep -nE "^[^#]*\b${_fn} \"" "$RUNNER" 2>/dev/null || true)"
    _calls=0
    if [[ -n "$_hits" ]]; then
        _real=()
        while IFS= read -r _line; do
            [[ "$_line" =~ ^[0-9]+:[[:space:]]*# ]] && continue
            _real+=("$_line")
        done <<< "$_hits"
        _calls="${#_real[@]}"
    fi
    if [[ "${_calls:-0}" -ge 1 ]]; then
        assert_pass "[SPEC-1] $_fn has a production caller in runner.sh"
    else
        assert_fail "[SPEC-1] $_fn has a production caller in runner.sh" \
            "0 call sites — the table is defined and never consulted (#1887)"
    fi
done

# ─── SPEC-2: the re-dispatch budget is bounded and validated ─────────────────
print_test_section "SPEC-2: the re-dispatch budget refuses nonsense"

# Extract the helper from runner.sh without executing the whole file: sourcing
# runner.sh is guarded to not run main(), but the helper is nested inside it.
_budget_body="$(sed -n '/_runner_disposition_redispatch_budget() {/,/^    }/p' "$RUNNER")"
if [[ -z "$_budget_body" ]]; then
    assert_fail "[SPEC-2] the budget helper exists" "not found in runner.sh"
else
    assert_pass "[SPEC-2] the budget helper exists"
    eval "${_budget_body#"${_budget_body%%[![:space:]]*}"}" 2>/dev/null || true
    if declare -F _runner_disposition_redispatch_budget >/dev/null 2>&1; then
        assert_eq "[SPEC-2] default is 1 (one automatic second attempt)" \
            "1" "$(_runner_disposition_redispatch_budget)"
        assert_eq "[SPEC-2] an explicit 0 opts out" \
            "0" "$(ZBUILD_DISPOSITION_REDISPATCH=0 _runner_disposition_redispatch_budget)"
        assert_eq "[SPEC-2] an explicit 3 is honoured" \
            "3" "$(ZBUILD_DISPOSITION_REDISPATCH=3 _runner_disposition_redispatch_budget)"
        # A grinding budget is refused rather than trusted — the cycle already
        # re-runs members; this exists to separate interrupted from failed.
        assert_eq "[SPEC-2] an out-of-range value clamps to the default" \
            "1" "$(ZBUILD_DISPOSITION_REDISPATCH=99 _runner_disposition_redispatch_budget)"
        assert_eq "[SPEC-2] a non-numeric value clamps to the default" \
            "1" "$(ZBUILD_DISPOSITION_REDISPATCH=lots _runner_disposition_redispatch_budget)"
    else
        assert_fail "[SPEC-2] the budget helper is callable" "eval did not define it"
    fi
fi

# ─── SPEC-3: retryable and halting are disjoint, and the wiring relies on it ─
print_test_section "SPEC-3: the words the wiring branches on behave as the table says"

source "$REPO_ROOT/core/pipeline/disposition.sh"

for _d in interrupted throttled; do
    if disposition_retryable "$_d" 2>/dev/null; then
        assert_pass "[SPEC-3] $_d is retryable — re-dispatched without any router.retries knob"
    else
        assert_fail "[SPEC-3] $_d is retryable" "table says otherwise"
    fi
    if disposition_halts "$_d" 2>/dev/null; then
        assert_fail "[SPEC-3] $_d does not halt" "both retries AND halts"
    else
        assert_pass "[SPEC-3] $_d does not halt"
    fi
done

for _d in broken unavailable; do
    if disposition_halts "$_d" 2>/dev/null; then
        assert_pass "[SPEC-3] $_d halts — no re-dispatch even with a retries knob set"
    else
        assert_fail "[SPEC-3] $_d halts" "table says otherwise"
    fi
    if disposition_retryable "$_d" 2>/dev/null; then
        assert_fail "[SPEC-3] $_d is not retryable" "a halted stage would be re-dispatched"
    else
        assert_pass "[SPEC-3] $_d is not retryable"
    fi
done

# `exhausted` is neither: retrying the same budget learns nothing, and the cycle
# owns the escalation.
if disposition_retryable exhausted 2>/dev/null; then
    assert_fail "[SPEC-3] exhausted is not re-dispatched here" "would burn the same budget twice"
else
    assert_pass "[SPEC-3] exhausted is not re-dispatched here (the cycle escalates)"
fi

# ─── SPEC-4: throttled waits, interrupted does not ───────────────────────────
# The number is what separates the two words. A throttled stage re-dispatched
# immediately is simply throttled again.
print_test_section "SPEC-4: disposition_wait_s is what distinguishes throttled"

assert_eq "[SPEC-4] interrupted re-dispatches immediately" \
    "0" "$(disposition_wait_s interrupted)"
_tw="$(disposition_wait_s throttled)"
if [[ "$_tw" =~ ^[0-9]+$ ]] && (( _tw > 0 )); then
    assert_pass "[SPEC-4] throttled waits before re-dispatch (${_tw}s)"
else
    assert_fail "[SPEC-4] throttled waits before re-dispatch" "got '$_tw'"
fi

# ─── SPEC-5: the wiring emits an operator-visible decision ───────────────────
print_test_section "SPEC-5: the decision is announced, not inferred from an rc"

for _ev in cycle.member.disposition.redispatch cycle.member.disposition.halt; do
    if grep -q "\"$_ev\"" "$REPO_ROOT/config/event-schema.json"; then
        assert_pass "[SPEC-5] $_ev is registered in the engine schema"
    else
        assert_fail "[SPEC-5] $_ev is registered in the engine schema" "unregistered event"
    fi
    if grep -q "$_ev" "$RUNNER"; then
        assert_pass "[SPEC-5] $_ev is emitted by the dispatch path"
    else
        assert_fail "[SPEC-5] $_ev is emitted by the dispatch path" "no emitter"
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
