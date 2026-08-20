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
#   T2: _cycle_apply_feedback copies design iter-1's design.md to
#       cycle-design_verify_cycle/iter-2/feedback/design.txt verbatim.
#   T3: Co-fires with impact_feedback_md edge — both design.txt AND
#       design_gate_feedback.txt land in the same iter-2/feedback dir.
#   T4: Empty (zero-byte) prior design.md + required=false → rc=0, no feedback
#       file written, no fatal error (fail-soft contract).
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
assert_contains "[SPEC-6] T1: feedback contains design-gate→design edge" \
    "$fb" "design-gate:design_gate_feedback|design:design_gate_feedback"
assert_contains "[SPEC-6] T1: feedback contains design→design self-edge (#842)" \
    "$fb" "design:design|design:design"

# Both edges present means two records separated by newline.
edge_count="$(printf '%s\n' "$fb" | grep -c '|' || true)"
assert_eq "[SPEC-6] T1: exactly 2 feedback edges in design_verify_cycle" "2" "$edge_count"

# ─── T2 + T3: _cycle_apply_feedback round-trips both edges ──────────────────
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR/artifacts/design" "$STATE_DIR/artifacts/impact"

# Simulate iter-1 outputs: design.md + impact_feedback_md.
_DESIGN_MD_SENTINEL='# Design v1\n```scope\ncore/foo.sh\ntests/foo-test.sh\n```'
_IMPACT_FEEDBACK_SENTINEL='## Gap report — missing config/bar.yaml'
printf '%s' "$_DESIGN_MD_SENTINEL" > "$STATE_DIR/artifacts/design/design.md"
printf '%s' "$_IMPACT_FEEDBACK_SENTINEL" > "$STATE_DIR/artifacts/impact/impact_feedback_md.md"

_CYCLE_TRAP_CYCLE_ID="design_verify_cycle"
# Wire BOTH edges as the orchestrator would (uses _TPL_CYCLE_FEEDBACK shape).
_CYCLE_FEEDBACK=(
    "impact:impact_feedback_md.md|design:design_gate_feedback:false"
    "design:design.md|design:design:false"
)
set +e; _cycle_apply_feedback 2 "$STATE_DIR"; rc=$?; set -e
assert_eq "T2: both feedback edges apply → rc=0" "0" "$rc"

# T2: design.txt landed in iter-2 feedback dir.
PRIOR_DESIGN_DST="$STATE_DIR/cycle-design_verify_cycle/iter-2/feedback/design.txt"
assert_file_exists "T2: design.txt copied to iter-2 feedback dir" "$PRIOR_DESIGN_DST"

# T2: body is byte-identical (raw-copy convention).
assert_eq "T2: design.txt body matches iter-1 design.md verbatim" \
    "$_DESIGN_MD_SENTINEL" "$(cat "$PRIOR_DESIGN_DST")"

# T3: impact_feedback_md side-edge co-fired.
PRIOR_IMPACT_DST="$STATE_DIR/cycle-design_verify_cycle/iter-2/feedback/design_gate_feedback.txt"
assert_file_exists "T3: design_gate_feedback.txt also copied (co-fire)" "$PRIOR_IMPACT_DST"
assert_eq "T3: design_gate_feedback.txt body matches iter-1 impact verbatim" \
    "$_IMPACT_FEEDBACK_SENTINEL" "$(cat "$PRIOR_IMPACT_DST")"

# ─── T4: fail-soft when prior design.md missing + required=false ────────────
STATE_DIR2="$TEST_TEMP_DIR/state2"
mkdir -p "$STATE_DIR2/artifacts/design" "$STATE_DIR2/artifacts/impact"
# Note: design.md deliberately absent.
printf '%s' "$_IMPACT_FEEDBACK_SENTINEL" > "$STATE_DIR2/artifacts/impact/impact_feedback_md.md"

_CYCLE_FEEDBACK=(
    "design:design.md|design:design:false"
)
: > "$ZBUILD_EVENTS_JSONL"
set +e; _cycle_apply_feedback 2 "$STATE_DIR2"; rc=$?; set -e
assert_eq "T4: missing optional self-edge from-artifact → rc=0 (fail-soft)" "0" "$rc"

if [[ -f "$STATE_DIR2/cycle-design_verify_cycle/iter-2/feedback/design.txt" ]]; then
    assert_fail "T4: no design.txt written when source missing"
else
    assert_pass "T4: no design.txt written when source missing"
fi

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
