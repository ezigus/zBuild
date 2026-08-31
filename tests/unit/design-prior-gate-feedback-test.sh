#!/usr/bin/env bash
# Unit (#1219, ADR-045/ADR-046): design splices the prior_gate_feedback payload
# (design-feedback.md, written by the gate-aggregator on a route_design verdict)
# into its prompt on a route_back REPLAY, so the re-authoring design pass sees the
# named tautological [change] SPECs. On the FIRST design pass the file is absent
# (required:false) → the prompt is byte-identical to the no-feedback case (no-op).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: design prior_gate_feedback splice (#1219, ADR-046)"
setup_test_env "design-prior-gate-feedback-1219"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# Mock the router loop to a no-op success — we only inspect the prompt the inner
# function writes to <artifact_dir>/design-prompt.txt before routing.
route_to_model_loop() {
    [[ -n "${MOCK_DESIGN_WRITE_PATH:-}" ]] && {
        mkdir -p "$(dirname "$MOCK_DESIGN_WRITE_PATH")"
        printf '# Design\n\n```scope\nfoo.sh\n```\n' > "$MOCK_DESIGN_WRITE_PATH"
    }
    _ROUTE_LOOP_FINAL_OUTPUT="ok"; _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { local dest="$1"; cat - > "$dest"; }
_route_loop_close_final_banner() { return 0; }

_setup_fixture() {  # → echoes ARTIFACT_DIR
    local fix; fix="$(mktemp -d "$TEST_TEMP_DIR/fix.XXXXXX")"
    git -C "$fix" init --quiet >/dev/null 2>&1
    git -C "$fix" config user.email 'test@example.com' >/dev/null
    git -C "$fix" config user.name 'test' >/dev/null
    local ad="$fix/state/artifacts"; mkdir -p "$ad"
    printf 'scope: all\n' > "$fix/state/scope-manifest.md"
    cat > "$ad/plan.json" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
    export ZBUILD_REPO_ROOT="$fix"
    printf '%s' "$ad"
}

# ── T1: design-feedback.md present → its body is spliced into the prompt ──────
AD1="$(_setup_fixture)"
cat > "$AD1/design-feedback.md" <<'EOF'
# Design-rooted gate feedback
SPEC-7 is tautological (pass at baseline) — re-author the assertion.
EOF
export MOCK_DESIGN_WRITE_PATH="$AD1/design.md"
_design_stage_run_inner "$(dirname "$AD1")/scope-manifest.md" "$AD1/plan.json" "$AD1/design.md" "$AD1" >/dev/null 2>&1 || true
PROMPT1="$AD1/design-prompt.txt"
assert_file_exists "T1: design prompt written" "$PROMPT1"
# #1988: design no longer splices design-feedback.md — the aggregator stopped
# writing it, and the acceptance gate's own summary carries the detail now. What
# design still owns is the INSTRUCTION, which it emits when the gate's recorded
# verdict is a failure. The body assertion moves to where that summary is
# produced; the instruction is asserted here, because design owns it.
if grep -qF 'SPEC-7 is tautological' "$PROMPT1"; then
    assert_fail "T1: design does not re-splice the gate's detail" \
        "the retired section is still emitted"
else
    assert_pass "T1: design does not re-splice the gate's detail"
fi
# Driven as its own fixture: the instruction is keyed on the gate's recorded
# verdict, so the state must exist before the stage runs.
AD1B="$(_setup_fixture)"
printf '{"schema_version":1,"stage_verdicts":{"acceptance-gate":"fail"}}\n' \
    > "$(dirname "$AD1B")/pipeline-state.json"
export MOCK_DESIGN_WRITE_PATH="$AD1B/design.md"
_design_stage_run_inner "$(dirname "$AD1B")/scope-manifest.md" "$AD1B/plan.json" \
    "$AD1B/design.md" "$AD1B" >/dev/null 2>&1 || true
assert_contains_regex "T1: a failing acceptance gate yields the re-author instruction" \
    "$(cat "$AD1B/design-prompt.txt" 2>/dev/null)" "RE-AUTHOR"

# ── T2: design-feedback.md absent → prompt has NO gate-feedback section (no-op) ─
AD2="$(_setup_fixture)"
export MOCK_DESIGN_WRITE_PATH="$AD2/design.md"
_design_stage_run_inner "$(dirname "$AD2")/scope-manifest.md" "$AD2/plan.json" "$AD2/design.md" "$AD2" >/dev/null 2>&1 || true
PROMPT2="$AD2/design-prompt.txt"
assert_file_exists "T2: design prompt written (no feedback)" "$PROMPT2"
if grep -qi 'PRIOR GATE FEEDBACK' "$PROMPT2"; then
    assert_fail "T2: first pass (no design-feedback.md) must NOT add a gate-feedback section" \
        "$(grep -i 'PRIOR GATE FEEDBACK' "$PROMPT2")"
else
    assert_pass "T2: first pass omits the gate-feedback section (no-op when file absent)"
fi

# ── T3 / [SPEC-3]: design-gate-feedback.md present → spliced as distinct section ─
# #1479: design-gate-feedback.md in the shared artifacts dir must be read by
# _design_read_design_gate_feedback and spliced with a "PRIOR DESIGN-GATE FEEDBACK"
# heading so the design pass sees structural violations from the prior cycle.
AD3="$(_setup_fixture)"
cat > "$AD3/design-gate-feedback.md" <<'EOF'
# Design-gate violations
Scope block missing tests/unit/foo-test.sh for changed enum.
EOF
export MOCK_DESIGN_WRITE_PATH="$AD3/design.md"
_design_stage_run_inner "$(dirname "$AD3")/scope-manifest.md" "$AD3/plan.json" "$AD3/design.md" "$AD3" >/dev/null 2>&1 || true
PROMPT3="$AD3/design-prompt.txt"
assert_file_exists "T3: design prompt written (design-gate-feedback)" "$PROMPT3"
# #1979: design no longer splices this itself — the content reaches the prompt
# as an engine-collected summary (#1976), spliced exactly once, which is what
# #1825's dedup fix requires. What design still owns is the WORDING of the
# refinement instruction, and that now keys on the gate's recorded verdict.
if grep -qF 'PRIOR DESIGN-GATE FEEDBACK' "$PROMPT3"; then
    assert_fail "[SPEC-3] T3: design does not splice the summary a second time" \
        "the retired section is still emitted — the #1825 duplication"
else
    assert_pass "[SPEC-3] T3: design does not splice the summary a second time"
fi
# The refinement-instruction branch itself is covered behaviourally in
# tests/unit/design-summary-switch-test.sh; this fixture has no prior design, so
# that section is legitimately absent here.

# ── T4: design-gate-feedback.md absent → no section in prompt (no-op) ─
AD4="$(_setup_fixture)"
export MOCK_DESIGN_WRITE_PATH="$AD4/design.md"
_design_stage_run_inner "$(dirname "$AD4")/scope-manifest.md" "$AD4/plan.json" "$AD4/design.md" "$AD4" >/dev/null 2>&1 || true
PROMPT4="$AD4/design-prompt.txt"
assert_file_exists "T4: design prompt written (no design-gate-feedback)" "$PROMPT4"
# Unchanged in meaning by #1979: design emits no gate-feedback section of its
# own on a first pass — and now emits none on any pass, the engine having taken
# over the splice. The no-op guard still holds.
if grep -q 'PRIOR DESIGN-GATE FEEDBACK' "$PROMPT4"; then
    assert_fail "T4: first pass must NOT add a design-gate-feedback section" \
        "$(grep 'PRIOR DESIGN-GATE FEEDBACK' "$PROMPT4")"
else
    assert_pass "T4: first pass omits the design-gate-feedback section"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
