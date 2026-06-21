#!/usr/bin/env bash
# Tests: build prompt v2 framing — ORIGINAL TASK / INSTRUCTIONS /
# CURRENT ITERATION FEEDBACK sections + iter N/MAX banner (#571).
#
# Verifies the three-section structure the LLM sees:
#   - Iter 1: banner + ORIGINAL TASK + INSTRUCTIONS, NO FEEDBACK section.
#   - Iter 2+: same plus CURRENT ITERATION FEEDBACK containing the contents
#     of $ZBUILD_CYCLE_FEEDBACK_DIR/prior_test_assessment.txt (wired by #568).
#   - Banner shows "iter N/MAX" accurately.
#   - _build_read_prior_assessment is the new name; reads
#     prior_test_assessment.txt (not legacy prior_test_failures.txt).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build prompt v2 framing (#571)"
setup_test_env "build-prompt-framing"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# Capture the assembled prompt by mocking route_to_model_loop.
export _MOCK_ROUTE_CAPTURE="$TEST_TEMP_DIR/route-prompt.txt"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

route_to_model_loop() {
    local _prompt_file="$2"
    [[ -f "$_prompt_file" ]] && cp "$_prompt_file" "$_MOCK_ROUTE_CAPTURE"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}

# Surface max iter to header — route resolver returns 3 so banner reads "iter N/3".
_route_resolve_max_iterations() { echo 3; }

# Fresh git repo so the post-loop `git diff HEAD` capture works.
_FRAMING_REPO="$TEST_TEMP_DIR/framing-repo"
mkdir -p "$_FRAMING_REPO"
( cd "$_FRAMING_REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null
export ZBUILD_REPO_ROOT="$_FRAMING_REPO"

# Pass-through redaction (no manifest needed for framing tests).
apply_scope_redaction() {
    local in="$1" out="$2"
    cp "$in" "$out"
    return 0
}

artifact_dir="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$artifact_dir"
plan_path="$artifact_dir/plan.json"
cat > "$plan_path" <<'EOF'
{
  "title": "Framing fixture plan",
  "goal": "Verify prompt v2 framing sections",
  "steps": [
    {"id": 1, "description": "do thing", "files": ["a.sh"]}
  ]
}
EOF

scope_manifest="$TEST_TEMP_DIR/state/scope-manifest.md"
touch "$scope_manifest"

# ─── Iter 1 — no cycle context, no FEEDBACK section ─────────────────────────
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR
: > "$_MOCK_ROUTE_CAPTURE"

set +e
_build_stage_run_inner \
    "$scope_manifest" \
    "$plan_path" \
    "$artifact_dir/diff.patch" \
    "$artifact_dir/build-summary.json" \
    "$artifact_dir" >/dev/null 2>&1
rc1=$?
set -e

assert_eq "F1: iter 1 build inner rc=0" "0" "$rc1"

iter1_prompt="$(cat "$_MOCK_ROUTE_CAPTURE" 2>/dev/null || echo '')"

# F2: banner present and reads "iter 1/3"
assert_contains "F2: iter 1 banner present" "$iter1_prompt" "ZBUILD BUILD"
assert_contains "F2: iter 1 banner reads 'iter 1/3'" "$iter1_prompt" "iter 1/3"

# F3: ORIGINAL TASK section header present
assert_contains "F3: iter 1 has ORIGINAL TASK section" "$iter1_prompt" \
    "## ORIGINAL TASK"

# F4: INSTRUCTIONS section header present
assert_contains "F4: iter 1 has INSTRUCTIONS section" "$iter1_prompt" \
    "## INSTRUCTIONS"

# F5: CURRENT ITERATION FEEDBACK section ABSENT on iter 1
if grep -qF "## CURRENT ITERATION FEEDBACK" <<< "$iter1_prompt"; then
    assert_fail "F5: iter 1 must NOT include CURRENT ITERATION FEEDBACK" \
        "found unexpected section"
else
    assert_pass "F5: iter 1 omits CURRENT ITERATION FEEDBACK section"
fi

# ─── Iter 2 — cycle context with prior_test_assessment.txt ──────────────────
FB_DIR="$TEST_TEMP_DIR/fb-iter-2"
mkdir -p "$FB_DIR"
ASSESSMENT_BODY='## Test assessment (iter 1)

verdict: fail
- test/x_test.sh: FAIL line 42'
printf '%s\n' "$ASSESSMENT_BODY" > "$FB_DIR/prior_test_assessment.txt"

export ZBUILD_CYCLE_ITER=2
export ZBUILD_CYCLE_FEEDBACK_DIR="$FB_DIR"

: > "$_MOCK_ROUTE_CAPTURE"

set +e
_build_stage_run_inner \
    "$scope_manifest" \
    "$plan_path" \
    "$artifact_dir/diff.patch" \
    "$artifact_dir/build-summary.json" \
    "$artifact_dir" >/dev/null 2>&1
rc2=$?
set -e

assert_eq "F6: iter 2 build inner rc=0" "0" "$rc2"

iter2_prompt="$(cat "$_MOCK_ROUTE_CAPTURE" 2>/dev/null || echo '')"

# F7: banner shows iter 2/3
assert_contains "F7: iter 2 banner reads 'iter 2/3'" "$iter2_prompt" "iter 2/3"

# F8: ORIGINAL TASK + INSTRUCTIONS still present
assert_contains "F8: iter 2 has ORIGINAL TASK section" "$iter2_prompt" \
    "## ORIGINAL TASK"
assert_contains "F8: iter 2 has INSTRUCTIONS section" "$iter2_prompt" \
    "## INSTRUCTIONS"

# F9: CURRENT ITERATION FEEDBACK present + contains the assessment body
assert_contains "F9: iter 2 has CURRENT ITERATION FEEDBACK section" \
    "$iter2_prompt" "## CURRENT ITERATION FEEDBACK"
assert_contains "F9: iter 2 FEEDBACK contains prior assessment body" \
    "$iter2_prompt" "test/x_test.sh: FAIL line 42"

# ─── Iter 2 with EMPTY feedback file — FEEDBACK section omitted (silent guard)
: > "$FB_DIR/prior_test_assessment.txt"
: > "$_MOCK_ROUTE_CAPTURE"

set +e
_build_stage_run_inner \
    "$scope_manifest" \
    "$plan_path" \
    "$artifact_dir/diff.patch" \
    "$artifact_dir/build-summary.json" \
    "$artifact_dir" >/dev/null 2>&1
set -e

iter2_empty_prompt="$(cat "$_MOCK_ROUTE_CAPTURE" 2>/dev/null || echo '')"
if grep -qF "## CURRENT ITERATION FEEDBACK" <<< "$iter2_empty_prompt"; then
    assert_fail "F10: empty feedback file must NOT emit FEEDBACK section" \
        "silent-failure guard violated"
else
    assert_pass "F10: empty feedback file → FEEDBACK section omitted"
fi

# ─── F11: _build_read_prior_assessment is the canonical name (rename) ───────
if declare -F _build_read_prior_assessment >/dev/null 2>&1; then
    assert_pass "F11: _build_read_prior_assessment helper exists (rename complete)"
else
    assert_fail "F11: _build_read_prior_assessment must exist" \
        "rename from _build_read_prior_failures missing"
fi

# ─── F12: _build_render_task_header emits banner with iter N/MAX ────────────
if declare -F _build_render_task_header >/dev/null 2>&1; then
    hdr="$(_build_render_task_header 2 5)"
    assert_contains "F12: header banner contains 'ZBUILD BUILD'" "$hdr" "ZBUILD BUILD"
    assert_contains "F12: header banner contains 'iter 2/5'" "$hdr" "iter 2/5"
else
    assert_fail "F12: _build_render_task_header helper must exist" "missing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
