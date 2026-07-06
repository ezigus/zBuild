#!/usr/bin/env bash
# Integration: ADR-026 review remediation cycle MAX-ITER path (Wave 18-B, #707).
#
# Drives the OUTER build_review_cycle with review.verdict=request_changes EVERY
# iteration. exit_when never fires; max_iterations: 2 cap is hit; on_max:
# continue lets the pipeline fall through (matches ADR-019 fall-through to
# operator — _RUNNER_CYCLE_UNCONVERGED is set, but the cycle does NOT abort).
#
# Asserts:
#   T1: orchestrator returns rc=1 (max_iterations termination CLASS — distinct
#       from rc=0 converged and from rc=6 cycle_abort). The runner reads
#       _CYCLE_ON_MAX=continue to translate rc=1 into pipeline fall-through
#       (NOT halt); the rc=1 itself is the orchestrator's max_iterations class.
#   T1: _CYCLE_LAST_TERMINATED_REASON=max_iterations
#   T2: exactly 2 review dispatches (the max_iterations cap)
#   T3: cycle.complete reason=max_iterations event emitted
#   T4: NO cycle_abort event — abort and max_iter are distinct termination
#       paths (ADR-027 break-out contract)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-026 build_review_cycle — max_iterations exhausted, on_max=continue (#707)"
setup_test_env "review-remediation-max-iter-707"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$REPO_ROOT/config/templates/standard.yaml"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

CASE_DIR="$TEST_TEMP_DIR/maxiter"
mkdir -p "$CASE_DIR/state/artifacts" "$CASE_DIR/events"
export ZBUILD_STATE_DIR="$CASE_DIR/state"
export ZBUILD_STATE_FILE="$CASE_DIR/state/pipeline-state.json"
export ZBUILD_EVENTS_DIR="$CASE_DIR/events"
export ZBUILD_EVENTS_JSONL="$CASE_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
: > "$ZBUILD_EVENTS_JSONL"
printf '{"schema_version":1,"status":"in_progress"}' > "$ZBUILD_STATE_FILE"

export _DISPATCH_LOG="$CASE_DIR/dispatch.log"
: > "$_DISPATCH_LOG"

cycle_dispatch_stage() {
    local stage="$1" iter="$2" state_file="$3"
    printf 'iter=%s stage=%s\n' "$iter" "$stage" >> "$_DISPATCH_LOG"
    local state_dir; state_dir="$(dirname "$state_file")"
    local artdir="$state_dir/artifacts"
    mkdir -p "$artdir"
    local v="pass"
    case "$stage" in
        build) v="pass" ;;
        test)
            v="pass"
            printf '{"verdict":"pass","failed":0,"passed":1}' > "$artdir/test-results.json"
            ;;
        test_assessment)
            v="pass"
            printf '## TA\nverdict: pass\n' > "$artdir/test-assessment.md"
            printf '{"verdict":"pass"}' > "$artdir/test-assessment.json"
            ;;
        review)
            # ALWAYS request_changes — exit_when never fires, max_iter cap hits.
            v="request_changes"
            printf '{"verdict":"request_changes","summary":"iter %s findings"}' \
                "$iter" > "$artdir/review.json"
            printf '# Review (iter %s)\n\nverdict: request_changes\n' \
                "$iter" > "$artdir/review.md"
            ;;
    esac
    _CYCLE_DISPATCH_VERDICT="$v"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

set +e
cycle_orchestrator_run "build_review_cycle" "$ZBUILD_STATE_DIR" "$ZBUILD_STATE_FILE"
RC=$?
set -e

# ─── T1: cap fires → rc=2 (max_iterations, tests PASSING) NOT rc=6 cycle_abort ─
# #1208 by-severity: at exhaustion the tests are passing (review just wants
# changes), so the outcome is unconverged→review rc=2 (not the old max_iterations
# rc=1; both are the same soft-continue class at the runner). The runner reads
# _CYCLE_ON_MAX=continue to decide fall-through vs. halt (ADR-021 v2 #527/#528).
# What matters here is rc != 6 — block aborts propagate rc=6; max_iter does NOT.
assert_eq "T1: build_review_cycle rc=2 (exhausted, tests passing → unconverged→review)" "2" "$RC"
if [[ "$RC" -ne 6 ]]; then
    assert_pass "T1: rc != 6 — max_iter is distinct from cycle_abort"
else
    assert_fail "T1: rc != 6" "got rc=$RC (cycle_abort class)"
fi
assert_eq "T1: _CYCLE_LAST_TERMINATED_REASON=max_iterations" \
    "max_iterations" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "T1: _CYCLE_ON_MAX=continue preserved on outer cycle" \
    "continue" "${_CYCLE_ON_MAX:-}"

# ─── T2: exactly 3 outer iters (= max_iterations cap) ────────────────────────
# Review dispatches uniquely identify outer iters. max_iterations: 3 (#951).
review_dispatch_n="$(grep -c 'stage=review' "$_DISPATCH_LOG" || true)"
assert_eq "T2: exactly 3 review dispatches (= max_iterations: 3)" \
    "3" "$review_dispatch_n"

# ─── T3: cycle.complete with reason=max_iterations ───────────────────────────
_cc_lines="$(grep '"type":"cycle.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if grep -q '"reason":"max_iterations"' <<< "$_cc_lines"; then
    assert_pass "T3: cycle.complete reason=max_iterations emitted"
else
    assert_fail "T3: cycle.complete reason=max_iterations" \
        "$(grep cycle.complete "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo '(none)')"
fi

# ─── T4: NO cycle_abort signaled (continue ≠ abort) ──────────────────────────
abort_n=0
if grep -q 'cycle_abort' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    abort_n="$(grep -c 'cycle_abort' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
fi
assert_eq "T4: 0 cycle_abort markers (max_iter + continue is distinct from abort)" \
    "0" "$abort_n"

print_test_results
