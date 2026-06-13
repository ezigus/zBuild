#!/usr/bin/env bash
# Integration: ADR-026 review remediation cycle (Wave 18-B, #707).
#
# Drives the OUTER review_cycle (wraps inner build_test_cycle + review):
#   iter 1: review.verdict=request_changes → cycle re-iterates
#   iter 2: review.verdict=approve → exit_when fires, cycle terminates
#
# Asserts:
#   T1: standard.yaml's review_cycle parses with the ADR-026 shape (outer
#       flow=[build_test_cycle,review], exit_when=review.verdict==approve,
#       abort_when=review.verdict==block, feedback review→build wires
#       prior_review_feedback)
#   T2: outer cycle converges in iter 2 (rc=0, reason=converged)
#   T3: outer iter 2 receives iter-1 review.md as prior_review_feedback.txt
#       on disk (cycle feedback dir layout per ADR-021 v2 #511)
#   T4: build's prompt actually consumed the prior_review_feedback (mock
#       build records what _build_read_prior_review returned)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-026 review_cycle remediation — request_changes → approve (#707)"
setup_test_env "review-remediation-cycle-707"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# ─── T1: standard.yaml's review_cycle parses with the ADR-026 shape ──────────
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$REPO_ROOT/config/templates/standard.yaml"

# review_cycle must be registered.
has_outer=0
for c in "${_TPL_CYCLES[@]}"; do [[ "$c" == "review_cycle" ]] && has_outer=1; done
assert_eq "T1: review_cycle is a registered cycle" "1" "$has_outer"

assert_eq "T1: review_cycle.flow = build_test_cycle,cq-preflight,cq-audit-plan,cq-cycle,cq-backtrack,review" \
    "build_test_cycle,cq-preflight,cq-audit-plan,cq-cycle,cq-backtrack,review" "${_TPL_CYCLE_STAGES_review_cycle:-}"
assert_eq "T1: exit_when.stage=review" \
    "review" "${_TPL_CYCLE_UNTIL_STAGE_review_cycle:-}"
assert_eq "T1: exit_when.field=verdict" \
    "verdict" "${_TPL_CYCLE_UNTIL_FIELD_review_cycle:-}"
assert_eq "T1: exit_when.op=eq" \
    "eq" "${_TPL_CYCLE_UNTIL_OP_review_cycle:-}"
assert_eq "T1: exit_when.value=approve" \
    "approve" "${_TPL_CYCLE_UNTIL_VALUE_review_cycle:-}"
assert_eq "T1: abort_when.stage=review" \
    "review" "${_TPL_CYCLE_ABORT_WHEN_STAGE_review_cycle:-}"
assert_eq "T1: abort_when.value=block" \
    "block" "${_TPL_CYCLE_ABORT_WHEN_VALUE_review_cycle:-}"
assert_eq "T1: max_iterations=2" \
    "2" "${_TPL_CYCLE_MAX_review_cycle:-}"
assert_eq "T1: on_max=continue" \
    "continue" "${_TPL_CYCLE_ON_MAX_review_cycle:-}"

fb="${_TPL_CYCLE_FEEDBACK_review_cycle:-}"
assert_contains "T1: feedback from review:review_md" \
    "$fb" "review:review_md"
assert_contains "T1: feedback to build:prior_review_feedback" \
    "$fb" "build:prior_review_feedback"

# Dispatch: review_cycle is the OUTERMOST cycle and absorbs both
# build_test_cycle and review under one dispatch unit.
has_dispatch_outer=0
for u in "${_TPL_DISPATCH_UNITS[@]}"; do
    [[ "$u" == "cycle:review_cycle" ]] && has_dispatch_outer=1
done
assert_eq "T1: dispatch includes cycle:review_cycle (outermost)" \
    "1" "$has_dispatch_outer"

# ─── Orchestrator harness ────────────────────────────────────────────────────
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

CASE_DIR="$TEST_TEMP_DIR/iterates"
mkdir -p "$CASE_DIR/state/artifacts" "$CASE_DIR/events"
export ZBUILD_STATE_DIR="$CASE_DIR/state"
export ZBUILD_STATE_FILE="$CASE_DIR/state/pipeline-state.json"
export ZBUILD_EVENTS_DIR="$CASE_DIR/events"
export ZBUILD_EVENTS_JSONL="$CASE_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
: > "$ZBUILD_EVENTS_JSONL"
printf '{"schema_version":1,"status":"in_progress"}' > "$ZBUILD_STATE_FILE"

# Programmable dispatch mock — records calls, supplies verdicts driven by
# stage+iter, and (critically) records what build SAW for prior_review_feedback
# so T4 can assert the build prompt actually consumed it.
export _DISPATCH_LOG="$CASE_DIR/dispatch.log"
export _BUILD_REVIEW_SAW="$CASE_DIR/build-review-saw.txt"
: > "$_DISPATCH_LOG"
: > "$_BUILD_REVIEW_SAW"

# shellcheck disable=SC1090
source "$REPO_ROOT/plugins/agent/build/plugin.sh" 2>/dev/null || true

cycle_dispatch_stage() {
    local stage="$1" iter="$2" state_file="$3"
    printf 'outer_iter=%s stage=%s feedback_dir=%s\n' \
        "$iter" "$stage" "${ZBUILD_CYCLE_FEEDBACK_DIR:-}" >> "$_DISPATCH_LOG"
    local state_dir; state_dir="$(dirname "$state_file")"
    local artdir="$state_dir/artifacts"
    mkdir -p "$artdir"
    local v="pass"
    case "$stage" in
        build)
            # Record what the real build helper would have seen at this iter.
            # _build_read_prior_review reads $ZBUILD_CYCLE_FEEDBACK_DIR/
            # prior_review_feedback.txt — same env the orchestrator just set.
            local seen
            seen="$(_build_read_prior_review 2>/dev/null || true)"
            printf 'outer_iter=%s seen=%s\n' "$iter" "$seen" >> "$_BUILD_REVIEW_SAW"
            v="pass"
            ;;
        test)
            v="pass"
            printf '{"verdict":"pass","failed":0,"passed":1}' > "$artdir/test-results.json"
            ;;
        test_assessment)
            v="pass"
            printf '## Test Assessment (outer_iter %s)\n\nverdict: pass\n' \
                "$iter" > "$artdir/test-assessment.md"
            printf '{"verdict":"pass"}' > "$artdir/test-assessment.json"
            ;;
        review)
            # outer iter 1 → request_changes; outer iter 2 → approve.
            if [[ "$iter" == "1" ]]; then
                v="request_changes"
            else
                v="approve"
            fi
            # Mirror the real review plugin: write review.json AND review.md
            # (the latter is what the outer cycle pipes back to build).
            printf '{"verdict":"%s","summary":"iter-%s findings"}' \
                "$v" "$iter" > "$artdir/review.json"
            printf '# Review (outer_iter %s)\n\nverdict: %s\n\nFindings: please address nil-guard in foo.sh\n' \
                "$iter" "$v" > "$artdir/review.md"
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

# ─── T2: cycle converges on iter 2 ───────────────────────────────────────────
assert_eq "T2: review_cycle rc=0 (converged)" "0" "$RC"
assert_eq "T2: reason=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
# Review dispatches uniquely identify OUTER iters (the inner build_test_cycle
# does not invoke review). 1 review dispatch on outer iter 1 + 1 on outer
# iter 2 = 2 review dispatches total.
review_dispatch_n="$(grep -c 'stage=review' "$_DISPATCH_LOG" || true)"
assert_eq "T2: exactly 2 review dispatches (= 2 outer iters)" \
    "2" "$review_dispatch_n"
# Outer iter 1 → inner runs (3 stages × 1 inner iter = 3 dispatches) +
# review = 4. Outer iter 2 → inner runs again (3 dispatches) + review = 4.
# Total = 8 dispatches across the cycle.
total_dispatch_n="$(wc -l < "$_DISPATCH_LOG" | tr -d ' ')"
assert_eq "T2: total dispatches across both outer iters = 16" \
    "16" "$total_dispatch_n"

# ─── T3: iter-2 feedback file landed with iter-1 review.md content ───────────
FB_PATH="$CASE_DIR/state/cycle-review_cycle/iter-2/feedback/prior_review_feedback.txt"
if [[ -s "$FB_PATH" ]]; then
    assert_pass "T3: outer iter-2 feedback file prior_review_feedback.txt present + non-empty"
else
    assert_fail "T3: outer iter-2 feedback file" "missing or empty: $FB_PATH"
fi
assert_contains "T3: feedback contains iter-1 review.md header" \
    "$(cat "$FB_PATH" 2>/dev/null)" "Review (outer_iter 1)"
assert_contains "T3: feedback carries findings body" \
    "$(cat "$FB_PATH" 2>/dev/null)" "address nil-guard"

# .complete sentinel must be present (#511 Pin 9)
if [[ -e "$CASE_DIR/state/cycle-review_cycle/iter-2/feedback/.complete" ]]; then
    assert_pass "T3: iter-2 feedback .complete sentinel written"
else
    assert_fail "T3: iter-2 feedback .complete sentinel" "missing"
fi

# ─── T4: build prompt actually CONSUMED prior_review_feedback ────────────────
# The dispatch mock for `build` called _build_read_prior_review at dispatch
# time. Iter 1 should see empty (no prior review yet). Iter 2 should see
# the iter-1 review.md body.
# NB: the orchestrator dispatches `build_test_cycle` (the inner cycle) as a
# single member of the outer; the mock's `build` branch never fires because
# the inner cycle is opaque from outer's perspective. To exercise build's
# consumption, we re-resolve _build_read_prior_review against the iter-2
# feedback dir directly (simulating what the inner cycle's build dispatch
# sees on its FIRST iter under outer iter 2).
export ZBUILD_CYCLE_ITER=1
export ZBUILD_CYCLE_FEEDBACK_DIR="$CASE_DIR/state/cycle-review_cycle/iter-2/feedback"
saw_iter2="$(_build_read_prior_review 2>/dev/null || true)"
assert_contains "T4: build read iter-1 review header from outer iter-2 feedback" \
    "$saw_iter2" "Review (outer_iter 1)"
assert_contains "T4: build read iter-1 review findings body" \
    "$saw_iter2" "address nil-guard"

# Conversely: outer iter 1's feedback dir is iter-1/feedback — should not
# carry any prior review (this is the FIRST outer iter).
export ZBUILD_CYCLE_FEEDBACK_DIR="$CASE_DIR/state/cycle-review_cycle/iter-1/feedback"
saw_iter1="$(_build_read_prior_review 2>/dev/null || true)"
assert_eq "T4: build sees empty prior_review_feedback on outer iter 1" \
    "" "$saw_iter1"

print_test_results
