#!/usr/bin/env bash
# Integration: ADR-026 review remediation cycle ABORT path (Wave 18-B, #707).
#
# Drives the OUTER review_cycle with review.verdict=block on iter 1:
#   abort_when fires (rc=6 cycle_abort), propagates outward, terminates the
#   pipeline. Test stage from iter 2 NEVER runs.
#
# Asserts:
#   T1: orchestrator returns rc=6 (cycle_abort class, ADR-025)
#   T1: _CYCLE_LAST_TERMINATED_REASON=cycle_abort
#   T2: NO outer iter 2 dispatch happens (block terminates immediately)
#   T3: cycle.complete event with reason=cycle_abort is emitted in the
#       events.jsonl (downstream pipeline gating reads this)
#   T4: _zbuild_propagate_abort recognizes rc=6 and propagates outward
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-026 review_cycle — block → cycle_abort propagation (#707)"
setup_test_env "review-remediation-abort-707"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$REPO_ROOT/config/templates/standard.yaml"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

CASE_DIR="$TEST_TEMP_DIR/aborts"
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
            # ALWAYS block — exercise abort_when path.
            v="block"
            printf '{"verdict":"block","summary":"corrupt diff"}' > "$artdir/review.json"
            printf '# Review\n\nverdict: block\n' > "$artdir/review.md"
            ;;
    esac
    _CYCLE_DISPATCH_VERDICT="$v"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

set +e
cycle_orchestrator_run "review_cycle" "$ZBUILD_STATE_DIR" "$ZBUILD_STATE_FILE"
RC=$?
set -e

# ─── T1: rc=6 cycle_abort ────────────────────────────────────────────────────
assert_eq "T1: orchestrator returns rc=6 (cycle_abort)" "6" "$RC"
assert_eq "T1: _CYCLE_LAST_TERMINATED_REASON=cycle_abort" \
    "cycle_abort" "${_CYCLE_LAST_TERMINATED_REASON:-}"

# ─── T2: outer iter 2 never starts (block on iter 1 terminates) ──────────────
# Inner cycle (build_test_cycle) runs on outer iter 1 → 3 dispatches
# (build, test, test_assessment), each tagged iter=1 from inner's perspective.
# Review runs on outer iter 1 → 1 dispatch tagged iter=1.
# Total dispatches on iter 1 = 4. Outer iter 2 must NOT start, so no further
# dispatches happen.
review_dispatch_n="$(grep -c 'stage=review' "$_DISPATCH_LOG" || true)"
assert_eq "T2: exactly 1 review dispatch (no iter 2)" \
    "1" "$review_dispatch_n"
total_dispatch_n="$(wc -l < "$_DISPATCH_LOG" | tr -d ' ')"
assert_eq "T2: exactly 4 total dispatches (1 inner cycle + 1 review)" \
    "4" "$total_dispatch_n"

# ─── T3: cycle.complete with reason=cycle_abort emitted ──────────────────────
if grep -E '"type":"cycle.(complete|aborted)"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
   | grep -q '"reason":"cycle_abort"\|cycle_id.*review_cycle'; then
    assert_pass "T3: cycle terminal event references review_cycle + cycle_abort"
else
    assert_fail "T3: cycle terminal event" \
        "missing in $ZBUILD_EVENTS_JSONL"
fi

# ─── T4: _zbuild_propagate_abort handles rc=6 ────────────────────────────────
# shellcheck source=../../scripts/lib/abort-propagation.sh
source "$REPO_ROOT/scripts/lib/abort-propagation.sh"
set +e
_zbuild_propagate_abort 6; pr_rc=$?
set -e
assert_eq "T4: _zbuild_propagate_abort 6 returns 6" "6" "$pr_rc"

print_test_results
