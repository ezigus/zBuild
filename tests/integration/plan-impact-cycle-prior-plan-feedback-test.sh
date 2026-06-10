#!/usr/bin/env bash
# Integration test (#773): plan_impact_cycle's self-feedback edge in
# config/templates/standard.yaml wires plan iter-N's plan.json → iter-N+1's
# prior_plan.txt via the cycle orchestrator's existing _cycle_apply_feedback.
#
# Scope: orchestrator boundary (load real template + drive _cycle_apply_feedback
# directly). No real LLM, no real plan plugin invocation — verifies the
# wiring round-trips end-to-end with zero orchestrator code change (proves
# the survey's assumption that self-edges already work).
#
# Pinned assertions:
#   T1: standard.yaml load → _TPL_CYCLE_FEEDBACK_plan_impact_cycle contains
#       TWO newline-separated records: impact→plan AND plan→plan.
#   T2: _cycle_apply_feedback copies plan iter-1's plan.json to
#       cycle-plan_impact_cycle/iter-2/feedback/prior_plan.txt verbatim
#       (byte-for-byte; JSON-as-text convention).
#   T3: Co-fires with impact_feedback_md edge — both prior_plan.txt AND
#       prior_impact_feedback.txt land in the same iter-2/feedback dir.
#   T4: Empty (zero-byte) prior plan.json + required=false → rc=0, no feedback
#       file written, no fatal error (fail-soft contract).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plan_impact_cycle prior_plan self-feedback wiring (#773)"
setup_test_env "plan-impact-prior-plan-feedback"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# ─── T1: template loads with both feedback edges ────────────────────────────
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/standard.yaml"

fb="${_TPL_CYCLE_FEEDBACK_plan_impact_cycle:-}"
assert_contains "T1: feedback contains impact→plan edge" \
    "$fb" "impact:impact_feedback_md|plan:prior_impact_feedback"
assert_contains "T1: feedback contains plan→plan self-edge (#773)" \
    "$fb" "plan:plan|plan:prior_plan"

# Both edges present means two records separated by newline.
edge_count="$(printf '%s\n' "$fb" | grep -c '|' || true)"
assert_eq "T1: exactly 2 feedback edges in plan_impact_cycle" "2" "$edge_count"

# ─── T2 + T3: _cycle_apply_feedback round-trips both edges ──────────────────
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR/artifacts/plan" "$STATE_DIR/artifacts/impact"

# Simulate iter-1 outputs: plan.json + impact_feedback_md.
_PLAN_JSON_SENTINEL='{"schema_version":1,"steps":[{"id":"step-1","files":["sentinel.sh"]}]}'
_IMPACT_FEEDBACK_SENTINEL='## Gap report — missing config/foo.yaml'
printf '%s' "$_PLAN_JSON_SENTINEL" > "$STATE_DIR/artifacts/plan/plan.json"
printf '%s' "$_IMPACT_FEEDBACK_SENTINEL" > "$STATE_DIR/artifacts/impact/impact_feedback_md.md"

_CYCLE_TRAP_CYCLE_ID="plan_impact_cycle"
# Wire BOTH edges as the orchestrator would (uses _TPL_CYCLE_FEEDBACK shape).
_CYCLE_FEEDBACK=(
    "impact:impact_feedback_md.md|plan:prior_impact_feedback:false"
    "plan:plan.json|plan:prior_plan:false"
)
set +e; _cycle_apply_feedback 2 "$STATE_DIR"; rc=$?; set -e
assert_eq "T2: both feedback edges apply → rc=0" "0" "$rc"

# T2: prior_plan.txt landed in iter-2 feedback dir.
PRIOR_PLAN_DST="$STATE_DIR/cycle-plan_impact_cycle/iter-2/feedback/prior_plan.txt"
assert_file_exists "T2: prior_plan.txt copied to iter-2 feedback dir" "$PRIOR_PLAN_DST"

# T2: body is byte-identical (JSON-as-text raw-copy convention).
assert_eq "T2: prior_plan.txt body matches iter-1 plan.json verbatim" \
    "$_PLAN_JSON_SENTINEL" "$(cat "$PRIOR_PLAN_DST")"

# T3: impact_feedback_md side-edge co-fired.
PRIOR_IMPACT_DST="$STATE_DIR/cycle-plan_impact_cycle/iter-2/feedback/prior_impact_feedback.txt"
assert_file_exists "T3: prior_impact_feedback.txt also copied (co-fire)" "$PRIOR_IMPACT_DST"
assert_eq "T3: prior_impact_feedback.txt body matches iter-1 impact verbatim" \
    "$_IMPACT_FEEDBACK_SENTINEL" "$(cat "$PRIOR_IMPACT_DST")"

# ─── T4: fail-soft when prior plan.json missing + required=false ────────────
STATE_DIR2="$TEST_TEMP_DIR/state2"
mkdir -p "$STATE_DIR2/artifacts/plan" "$STATE_DIR2/artifacts/impact"
# Note: plan.json deliberately absent.
printf '%s' "$_IMPACT_FEEDBACK_SENTINEL" > "$STATE_DIR2/artifacts/impact/impact_feedback_md.md"

_CYCLE_FEEDBACK=(
    "plan:plan.json|plan:prior_plan:false"
)
: > "$ZBUILD_EVENTS_JSONL"
set +e; _cycle_apply_feedback 2 "$STATE_DIR2"; rc=$?; set -e
assert_eq "T4: missing optional self-edge from-artifact → rc=0 (fail-soft)" "0" "$rc"

if [[ -f "$STATE_DIR2/cycle-plan_impact_cycle/iter-2/feedback/prior_plan.txt" ]]; then
    assert_fail "T4: no prior_plan.txt written when source missing"
else
    assert_pass "T4: no prior_plan.txt written when source missing"
fi

# T4: the orchestrator still records the miss as an event for forensics.
assert_contains "T4: cycle.feedback.missing event emitted for forensics" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.feedback.missing"

# ─── T5: required=true symmetric — missing prior plan with required=true → rc!=0 ─
# Locks the required=true contract: if anyone flips the new self-edge from
# optional to required in standard.yaml, missing artifacts MUST fail-closed.
# Without this assertion, a config drift could silently fail-soft and
# reproduce the original amnesia bug.
STATE_DIR3="$TEST_TEMP_DIR/state3"
mkdir -p "$STATE_DIR3/artifacts/plan"
# plan.json deliberately absent.

_CYCLE_FEEDBACK=(
    "plan:plan.json|plan:prior_plan:true"
)
: > "$ZBUILD_EVENTS_JSONL"
set +e; _cycle_apply_feedback 2 "$STATE_DIR3"; rc=$?; set -e
assert_eq "T5: missing required=true self-edge → rc!=0 (fail-closed)" "1" "$rc"
assert_contains "T5: cycle.feedback.missing event emitted" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.feedback.missing"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
