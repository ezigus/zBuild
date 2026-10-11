#!/usr/bin/env bash
# Integration test (#842): the design-verify cycle's feedback wiring in
# config/templates/simple.yaml wires design-gate.design_gate_feedback → design's
# prior_impact_feedback AND design's own prior output → design's prior_design
# (self-feedback edge, mirrors #773 lesson from plan_impact_cycle).
#
# #979: repointed from standard.yaml's retired design_impact_cycle to simple.yaml's
# design_verify_cycle — the same two-edge feedback shape (a gate→design edge plus a
# design→design self-edge). T2–T5 exercise the generic _cycle_apply_feedback
# mechanic and are template-independent.
#
# Scope: orchestrator boundary (load real template + drive _cycle_apply_feedback
# directly). No real LLM, no real plugin invocation — verifies the wiring
# round-trips end-to-end with zero orchestrator code change.
#
# Pinned assertions:
#   T1: simple.yaml load → _TPL_CYCLE_FEEDBACK_design_verify_cycle contains
#       TWO newline-separated records: design-gate→design AND design→design.
#   T2: _cycle_apply_feedback copies NOTHING (ADR-068 §8): design reads its own
#       latest design.md where it wrote it; no iter-2/feedback dir is made.
#   T4: Missing prior design.md + required=false → rc=0, cycle.feedback.absent
#       (fail-soft contract).
#   T5: required=true symmetric — missing required artifact → rc!=0 (fail-closed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "design_verify_cycle self-feedback wiring (#842)"
setup_test_env "design-verify-self-feedback"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# ─── T1: template loads with both feedback edges ────────────────────────────
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/simple.yaml"

fb="${_TPL_CYCLE_FEEDBACK_design_verify_cycle:-}"
# #1979: the design-gate→design edge is retired — design-gate's feedback reaches
# design as an engine-collected summary (#1976) instead of a wire plus a bespoke
# reader. The SELF-edge is a different mechanism (design's own prior output,
# #842/#773) that nothing here replaces, so it must survive.
assert_contains "[SPEC-6] T1: feedback contains design→design self-edge (#842)" \
    "$fb" "design:design|design:design"
if grep -qF "design-gate:design_gate_feedback" <<< "$fb"; then
    assert_fail "[SPEC-6] T1: the design-gate→design edge is retired" "wire still parsed"
else
    assert_pass "[SPEC-6] T1: the design-gate→design edge is retired"
fi

# The self-edge is now the ONLY edge in this cycle.
edge_count="$(grep -c '|' <<< "$fb" || true)"
assert_eq "[SPEC-6] T1: exactly 1 feedback edge in design_verify_cycle" "1" "$edge_count"

# ─── T2: the self-edge copies nothing ─────────────────────────────────────
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR/artifacts/design"
printf '# Design v1\n' > "$STATE_DIR/artifacts/design/design.md"
_CYCLE_TRAP_CYCLE_ID="design_verify_cycle"
_CYCLE_FEEDBACK=("design:design.md|design:design:false")
set +e; _cycle_apply_feedback 2 "$STATE_DIR"; rc=$?; set -e
assert_eq "T2: the self-edge applies → rc=0" "0" "$rc"
if [[ -e "$STATE_DIR/cycle-design_verify_cycle/iter-2/feedback" ]]; then
    assert_fail "[ADR-068 §8] T2: no feedback copy of design.md is made" "copy dir exists"
else
    assert_pass "[ADR-068 §8] T2: no feedback copy of design.md is made"
fi

# ─── T4: fail-soft when prior design.md missing + required=false ────────────
STATE_DIR2="$TEST_TEMP_DIR/state2"
mkdir -p "$STATE_DIR2/artifacts/design" "$STATE_DIR2/artifacts/impact"
# Note: design.md deliberately absent.

_CYCLE_FEEDBACK=(
    "design:design.md|design:design:false"
)
: > "$ZBUILD_EVENTS_JSONL"
set +e; _cycle_apply_feedback 2 "$STATE_DIR2"; rc=$?; set -e
assert_eq "T4: missing optional self-edge from-artifact → rc=0 (fail-soft)" "0" "$rc"


# T4: the orchestrator records the optional miss as cycle.feedback.absent (not .missing).
assert_contains "[SPEC-1] T4: cycle.feedback.absent event emitted for optional miss" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.feedback.absent"

# ─── T5: required=true symmetric — missing with required=true → rc!=0 ───────
STATE_DIR3="$TEST_TEMP_DIR/state3"
mkdir -p "$STATE_DIR3/artifacts/design"
# design.md deliberately absent.

_CYCLE_FEEDBACK=(
    "design:design.md|design:design:true"
)
: > "$ZBUILD_EVENTS_JSONL"
set +e; _cycle_apply_feedback 2 "$STATE_DIR3"; rc=$?; set -e
assert_eq "T5: missing required=true self-edge → rc!=0 (fail-closed)" "1" "$rc"
assert_contains "[SPEC-2] T5: cycle.feedback.missing event emitted for required=true" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.feedback.missing"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
