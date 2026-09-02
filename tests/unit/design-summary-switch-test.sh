#!/usr/bin/env bash
# tests/unit/design-summary-switch-test.sh — design's refinement instruction
# keys on the design-gate VERDICT, not on having read a file (#1979).
#
# design's prompt used `_design_gate_fb_body` as a boolean switch: non-empty
# selected "Expand the PRIOR DESIGN scope block to cover the gaps named in
# PRIOR DESIGN-GATE FEEDBACK", empty selected the weaker "Refine the PRIOR
# DESIGN". Retiring the reader (#1976 delivers that content as an engine
# summary instead) would have silently pinned the prompt to the weak branch
# forever, with nothing failing.
#
# The replacement reads `.stage_verdicts["design-gate"]` from the run state — a
# fact, rather than a side effect of having read a file — and reuses the same
# verdict signal the summaries collector keys on.
#
#   SPEC-1 [change]: _design_gate_failed reads the verdict from run state
#   SPEC-2 [change]: design-gate failed  → the "expand the gaps" instruction
#   SPEC-3 [guard] : design-gate passed  → the plain "refine" instruction
#   SPEC-4 [change]: the bespoke reader and its splice are gone — the summaries
#                    block is the single source, preserving #1825's invariant
#                    that this content is spliced exactly once
#   SPEC-5 [guard] : the route_back design-rooted gate feedback is a DIFFERENT
#                    input (design_feedback, source: artifacts) and still works
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "design refinement switch keys on the gate verdict (#1979)"
setup_test_env "design-summary-switch"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh" 2>/dev/null || true

STATE_DIR="$TEST_TEMP_DIR/state"; ART="$STATE_DIR/artifacts"
mkdir -p "$ART"

_write_state() {
    cat > "$STATE_DIR/pipeline-state.json" <<EOF
{"schema_version":1,"stage_statuses":{"design-gate":"$1"},"stage_verdicts":{"design-gate":"$2"}}
EOF
}

# ─── SPEC-1: the verdict is readable ─────────────────────────────────────────
print_test_section "1. the design-gate verdict is read from run state"

if declare -F _design_gate_failed >/dev/null 2>&1; then
    _write_state failed fail
    if _design_gate_failed "$ART"; then
        assert_pass "[SPEC-1] a failed design-gate is detected"
    else
        assert_fail "[SPEC-1] a failed design-gate is detected" "returned non-zero"
    fi
    _write_state complete pass
    if _design_gate_failed "$ART"; then
        assert_fail "[SPEC-1] a passing design-gate is not treated as failed" "returned zero"
    else
        assert_pass "[SPEC-1] a passing design-gate is not treated as failed"
    fi
    rm -f "$STATE_DIR/pipeline-state.json"
    if _design_gate_failed "$ART"; then
        assert_fail "[SPEC-1] absent state is not treated as failed" "returned zero"
    else
        assert_pass "[SPEC-1] absent state is not treated as failed (first pass)"
    fi
else
    assert_fail "[SPEC-1] _design_gate_failed exists" "function not defined"
fi

# ─── SPEC-2 / SPEC-3: the branch keys on the verdict, not on a file read ─────
print_test_section "2. the refinement instruction branches on the gate verdict"

_p="$REPO_ROOT/plugins/agent/design/plugin.sh"
if grep -qF 'if _design_gate_failed' "$_p" 2>/dev/null; then
    assert_pass "[SPEC-2] the PRIOR DESIGN branch keys on the verdict"
else
    assert_fail "[SPEC-2] the PRIOR DESIGN branch keys on the verdict" \
        "the branch still keys on whether a file was read"
fi
assert_contains "[SPEC-2] the strong branch survives the rewiring" \
    "$(cat "$_p")" "Expand the PRIOR DESIGN scope block"
# It must point at a heading that still exists. The old text named PRIOR
# DESIGN-GATE FEEDBACK, which this change removes.
if grep -qF 'gaps named in PRIOR DESIGN-GATE FEEDBACK' "$_p" 2>/dev/null; then
    assert_fail "[SPEC-2] it points at a section that still exists" \
        "still references the retired PRIOR DESIGN-GATE FEEDBACK heading"
else
    assert_pass "[SPEC-2] it points at a section that still exists"
fi

print_test_section "3. the weak branch is preserved for a passing gate"
assert_contains "[SPEC-3] the plain refine instruction is still there" \
    "$(cat "$_p")" "Refine the PRIOR DESIGN"

# ─── SPEC-4: the bespoke reader and its section are gone ─────────────────────
print_test_section "4. the bespoke reader and its splice are retired"

_p="$REPO_ROOT/plugins/agent/design/plugin.sh"
if grep -qF '_design_read_design_gate_feedback' "$_p" 2>/dev/null; then
    assert_fail "[SPEC-4] _design_read_design_gate_feedback is gone" "the reader survives"
else
    assert_pass "[SPEC-4] _design_read_design_gate_feedback is gone"
fi
# #1825's invariant: this content is spliced exactly once. The summaries block
# is now that one place, so a second splice here would recreate the very
# duplication #1825 removed.
if grep -qF 'PRIOR DESIGN-GATE FEEDBACK (structural violations' "$_p" 2>/dev/null; then
    assert_fail "[SPEC-4] the duplicate splice section is gone" \
        "design still splices the content the summaries block carries"
else
    assert_pass "[SPEC-4] the duplicate splice section is gone"
fi
if grep -qE '^ +- id: design_gate_feedback' "$REPO_ROOT/plugins/agent/design/manifest.yaml" 2>/dev/null; then
    assert_fail "[SPEC-4] no inert input declaration is left behind" \
        "design still declares the retired input"
else
    assert_pass "[SPEC-4] no inert input declaration is left behind"
fi

# ─── SPEC-5: the route_back path is a different input and survives ───────────
print_test_section "5. the route_back design-rooted feedback still works"

# #1988 retired this one too: the aggregator stopped writing design-feedback.md,
# so the input had no producer. Design now keys its re-author instruction on the
# acceptance gate's recorded verdict and reads the detail from the summaries.
if grep -qF '_design_read_prior_gate_feedback' "$_p" 2>/dev/null; then
    assert_fail "[SPEC-5] the producerless route_back reader is retired" \
        "the reader survives with nothing to read"
else
    assert_pass "[SPEC-5] the producerless route_back reader is retired"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
