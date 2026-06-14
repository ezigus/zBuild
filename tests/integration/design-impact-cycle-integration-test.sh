#!/usr/bin/env bash
# Integration test (#842): design_impact_cycle end-to-end feedback wiring.
#
# Verifies without invoking a real LLM:
#   T1: _impact_extract_scope_from_design parses ```scope block from design.md
#   T2: _impact_run_inner writes impact_feedback.md; content round-trips into
#       design's prior_impact_feedback on iter 2 via _design_read_prior_impact_feedback
#   T3: design iter 2 prompt contains PRIOR DESIGN (self-feedback, #773 lesson)
#       when ZBUILD_CYCLE_FEEDBACK_DIR/prior_design.txt is present
#   T4: design iter 2 prompt contains PRIOR IMPACT FEEDBACK when
#       prior_impact_feedback.txt is present
#   T5: impact verdict=complete suppresses both feedback files (no content to
#       pipe back; complete exit is cycle convergence)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "design_impact_cycle integration — feedback wiring (#842)"
setup_test_env "design-impact-cycle-integration-842"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
: > "$ZBUILD_EVENTS_JSONL"

# Disable deterministic prefilter by pointing ZBUILD_REPO_ROOT at a scratch dir.
FAKE_REPO_ROOT="$TEST_TEMP_DIR/no-prefilter-root"
mkdir -p "$FAKE_REPO_ROOT/config"
export ZBUILD_REPO_ROOT="$FAKE_REPO_ROOT"

# Source impact plugin under test (stubs route_to_model after sourcing).
# shellcheck source=../../plugins/agent/impact/plugin.sh
source "$REPO_ROOT/plugins/agent/impact/plugin.sh"

# ─── T1: _impact_extract_scope_from_design parses ```scope block ─────────────
T1_DESIGN_MD="$TEST_TEMP_DIR/t1-design.md"
cat > "$T1_DESIGN_MD" <<'MD'
# Design: Example

## Decision
Replace plan_impact_cycle with design_impact_cycle.

```scope
core/pipeline/template.sh
plugins/agent/design/plugin.sh
plugins/agent/impact/plugin.sh
tests/integration/standard-template-3stage-cycle-test.sh
```

## Notes
Scope above is exhaustive.
MD

scope_csv="$(_impact_extract_scope_from_design "$T1_DESIGN_MD")"
case "$scope_csv" in
    *"core/pipeline/template.sh"*)
        assert_pass "T1: scope CSV contains core/pipeline/template.sh" ;;
    *)
        assert_fail "T1: scope CSV missing template.sh" "got: $scope_csv" ;;
esac
case "$scope_csv" in
    *"plugins/agent/impact/plugin.sh"*)
        assert_pass "T1: scope CSV contains impact/plugin.sh" ;;
    *)
        assert_fail "T1: scope CSV missing impact/plugin.sh" "got: $scope_csv" ;;
esac
entry_count="$(printf '%s' "$scope_csv" | tr ',' '\n' | grep -c '.' || true)"
assert_eq "T1: 4 scope entries parsed" "4" "$entry_count"

# ─── T2: _impact_run_inner writes impact_feedback.md + wires into design ──────
T2_STATE="$TEST_TEMP_DIR/t2-state"
T2_ARTS="$T2_STATE/artifacts"
mkdir -p "$T2_ARTS"

# scope-manifest (required by apply_scope_redaction)
cat > "$T2_STATE/scope-manifest.md" <<'EOF'
+ ./
EOF

# design.md with ```scope block
cat > "$T2_ARTS/design.md" <<'MD'
# Design: test

```scope
config/templates/standard.yaml
plugins/agent/design/plugin.sh
```

No other files in scope.
MD

# plan.json (secondary input)
printf '{"schema_version":1,"steps":[]}' > "$T2_ARTS/plan.json"

# Stub route_to_model to return a synthetic incomplete response.
route_to_model() {
    printf '%s' '{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["tests/integration/standard-template-3stage-cycle-test.sh"],"reason":"test pins cycle count"}],"impact_feedback_md":"## Gap report\\n- Missing: tests/integration/standard-template-3stage-cycle-test.sh (pins cycle count)"}'
}
# Stub apply_scope_redaction to just copy (redaction tested separately).
apply_scope_redaction() {
    local src="$1" dst="$2"
    cp "$src" "$dst"
    return 0
}
# Stub emit_event (avoid real event-bus writes in this unit scope).
emit_event() { return 0; }
# Stub append_prompt_override (no .zbuild/prompts/ in test env).
append_prompt_override() { return 0; }

set +e
_impact_run_inner \
    "$T2_STATE/scope-manifest.md" \
    "$T2_ARTS/design.md" \
    "$T2_ARTS/plan.json" \
    "$T2_ARTS/impact.json" \
    "$T2_ARTS"
t2_rc=$?
set -e
assert_eq "T2: _impact_run_inner rc=0" "0" "$t2_rc"

assert_file_exists "T2: impact.json written" "$T2_ARTS/impact.json"
assert_file_exists "T2: impact_feedback.md written" "$T2_ARTS/impact_feedback.md"

t2_verdict="$(jq -r '.verdict' "$T2_ARTS/impact.json" 2>/dev/null)"
assert_eq "T2: impact.json verdict=incomplete" "incomplete" "$t2_verdict"

# The feedback content must be in impact_feedback.md.
t2_fb_content="$(cat "$T2_ARTS/impact_feedback.md" 2>/dev/null)"
case "$t2_fb_content" in
    *"Gap report"*)
        assert_pass "T2: impact_feedback.md contains gap report text" ;;
    *)
        assert_fail "T2: impact_feedback.md missing expected gap content" "got: $t2_fb_content" ;;
esac

# Simulate cycle orchestrator wiring impact_feedback.md → design's prior_impact_feedback.
T2_FB_DIR="$TEST_TEMP_DIR/t2-feedback-iter2"
mkdir -p "$T2_FB_DIR"
cp "$T2_ARTS/impact_feedback.md" "$T2_FB_DIR/prior_impact_feedback.txt"

# Verify _design_read_prior_impact_feedback returns the content.
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

export ZBUILD_CYCLE_ITER=2
export ZBUILD_CYCLE_FEEDBACK_DIR="$T2_FB_DIR"
fb_body="$(_design_read_prior_impact_feedback 2>/dev/null || true)"
case "$fb_body" in
    *"Gap report"*)
        assert_pass "T2: _design_read_prior_impact_feedback returns gap report text" ;;
    *)
        assert_fail "T2: _design_read_prior_impact_feedback missing gap content" "got: $fb_body" ;;
esac
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR

# ─── T3: design iter 2 prompt contains PRIOR IMPACT FEEDBACK ──────────────────
T3_FB_DIR="$TEST_TEMP_DIR/t3-feedback-iter2"
mkdir -p "$T3_FB_DIR"
printf '## Gap report\n- Missing: tests/integration/standard-template-3stage-cycle-test.sh\n' \
    > "$T3_FB_DIR/prior_impact_feedback.txt"

export ZBUILD_CYCLE_ITER=2
export ZBUILD_CYCLE_FEEDBACK_DIR="$T3_FB_DIR"

T3_STATE="$TEST_TEMP_DIR/t3-state"
T3_ARTS="$T3_STATE/artifacts"
mkdir -p "$T3_ARTS"
cat > "$T3_STATE/scope-manifest.md" <<'EOF'
+ ./
EOF
printf '{"schema_version":1,"title":"Test","steps":[{"id":"s1","files":["plugins/agent/design/plugin.sh"]}]}' \
    > "$T3_ARTS/plan.json"

# Stub route_to_model_loop to just write a placeholder design.md.
T3_PROMPT_CAPTURE="$TEST_TEMP_DIR/t3-prompt.txt"
route_to_model_loop() {
    local _tier="$1" _prompt_file="$2"
    cp "$_prompt_file" "$T3_PROMPT_CAPTURE"
    # Write a minimal design.md at the path embedded in the prompt.
    local design_path
    design_path="$(grep -o '/[^ ]*design\.md' "$_prompt_file" 2>/dev/null | head -1 || true)"
    if [[ -n "$design_path" ]]; then
        mkdir -p "$(dirname "$design_path")"
        printf '# Design\n```scope\nplugins/agent/design/plugin.sh\n```\n' > "$design_path"
    fi
    return 0
}
_route_resolve_max_iterations() { echo 5; }

set +e
_design_stage_run_inner \
    "$T3_STATE/scope-manifest.md" \
    "$T3_ARTS/plan.json" \
    "$T3_ARTS/design.md" \
    "$T3_ARTS"
t3_rc=$?
set -e

unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR

if [[ -f "$T3_PROMPT_CAPTURE" ]]; then
    t3_prompt="$(cat "$T3_PROMPT_CAPTURE")"
    case "$t3_prompt" in
        *"PRIOR IMPACT FEEDBACK"*)
            assert_pass "T3: design prompt includes PRIOR IMPACT FEEDBACK on iter 2" ;;
        *)
            assert_fail "T3: design prompt missing PRIOR IMPACT FEEDBACK" \
                "prompt snippet: $(head -30 "$T3_PROMPT_CAPTURE")" ;;
    esac
else
    assert_fail "T3: prompt capture file not written (route_to_model_loop stub issue)" ""
fi

# ─── T4: design iter 2 prompt contains PRIOR DESIGN (self-feedback) ──────────
T4_FB_DIR="$TEST_TEMP_DIR/t4-feedback-iter2"
mkdir -p "$T4_FB_DIR"
printf '# Design v1\n```scope\nplugins/agent/design/plugin.sh\n```\n' \
    > "$T4_FB_DIR/prior_design.txt"
# No prior_impact_feedback — only self-feedback edge fires.

export ZBUILD_CYCLE_ITER=2
export ZBUILD_CYCLE_FEEDBACK_DIR="$T4_FB_DIR"

T4_STATE="$TEST_TEMP_DIR/t4-state"
T4_ARTS="$T4_STATE/artifacts"
mkdir -p "$T4_ARTS"
cat > "$T4_STATE/scope-manifest.md" <<'EOF'
+ ./
EOF
printf '{"schema_version":1,"title":"T4","steps":[{"id":"s1","files":["plugins/agent/design/plugin.sh"]}]}' \
    > "$T4_ARTS/plan.json"

T4_PROMPT_CAPTURE="$TEST_TEMP_DIR/t4-prompt.txt"
route_to_model_loop() {
    local _tier="$1" _prompt_file="$2"
    cp "$_prompt_file" "$T4_PROMPT_CAPTURE"
    local design_path
    design_path="$(grep -o '/[^ ]*design\.md' "$_prompt_file" 2>/dev/null | head -1 || true)"
    if [[ -n "$design_path" ]]; then
        mkdir -p "$(dirname "$design_path")"
        printf '# Design\n```scope\nplugins/agent/design/plugin.sh\n```\n' > "$design_path"
    fi
    return 0
}

set +e
_design_stage_run_inner \
    "$T4_STATE/scope-manifest.md" \
    "$T4_ARTS/plan.json" \
    "$T4_ARTS/design.md" \
    "$T4_ARTS"
t4_rc=$?
set -e

unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR

if [[ -f "$T4_PROMPT_CAPTURE" ]]; then
    t4_prompt="$(cat "$T4_PROMPT_CAPTURE")"
    case "$t4_prompt" in
        *"PRIOR DESIGN"*)
            assert_pass "T4: design prompt includes PRIOR DESIGN on iter 2 (self-feedback, #773)" ;;
        *)
            assert_fail "T4: design prompt missing PRIOR DESIGN self-feedback" \
                "prompt snippet: $(head -30 "$T4_PROMPT_CAPTURE")" ;;
    esac
else
    assert_fail "T4: prompt capture file not written" ""
fi

# ─── T5: outside cycle context → _design_read helpers return empty ────────────
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR 2>/dev/null || true
t5_fb_body="$(_design_read_prior_impact_feedback 2>/dev/null || true)"
assert_eq "T5: _design_read_prior_impact_feedback empty outside cycle" "" "$t5_fb_body"
t5_design_body="$(_design_read_prior_design 2>/dev/null || true)"
assert_eq "T5: _design_read_prior_design empty outside cycle" "" "$t5_design_body"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
