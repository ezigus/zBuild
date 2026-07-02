#!/usr/bin/env bash
# Tests: build stage appends per-repo prompt override (OV-2 / #855, ADR-032)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build prompt override append (OV-2 / #855)"
setup_test_env "build-prompt-override"

# Sandbox state/events so build plugin's emits don't escape.
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# Mock the agent loop entry point to a no-op success (no real LLM call).
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}

# Pass-through redaction so the override marker survives into the redacted file
# (this is exactly what proves "append happened BEFORE redaction").
apply_scope_redaction() {
    local in="$1" out="$2"
    cp "$in" "$out"
    return 0
}

# ── Fixture target repo: ZBUILD_REPO_ROOT drives load_prompt_override's lookup ──
FIXTURE_REPO="$TEST_TEMP_DIR/fixture-repo"
mkdir -p "$FIXTURE_REPO/.zbuild/prompts"
( cd "$FIXTURE_REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null
export ZBUILD_REPO_ROOT="$FIXTURE_REPO"

OVERRIDE_FILE="$FIXTURE_REPO/.zbuild/prompts/build-overrides.md"
cat > "$OVERRIDE_FILE" <<'EOF'
This repo uses tabs. BUILD_OV_MARKER — prefer the domain helper for IO.
EOF

# ── Shared fixtures: plan.json + scope manifest (cribbed from render test) ──
artifact_dir="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$artifact_dir"
plan_path="$artifact_dir/plan.json"
cat > "$plan_path" <<'EOF'
{
  "title": "Test plan",
  "goal": "Verify override append",
  "steps": [
    {"id": 1, "description": "step one", "files": ["a.sh"]}
  ]
}
EOF

scope_manifest="$TEST_TEMP_DIR/state/scope-manifest.md"
touch "$scope_manifest"

run_build_inner() {
    set +e
    _build_stage_run_inner \
        "$scope_manifest" \
        "$plan_path" \
        "$artifact_dir/diff.patch" \
        "$artifact_dir/build-summary.json" \
        "$artifact_dir" >/dev/null 2>&1
    local rc=$?
    set -e 2>/dev/null || true
    return $rc
}

# ════════════════════════════════════════════════════════════════════════════
# WITH override file present
# ════════════════════════════════════════════════════════════════════════════
run_build_inner
rc=$?
assert_eq "build inner rc=0 (override present)" "0" "$rc"

prompt_txt="$artifact_dir/build-prompt.txt"
prompt_body="$(cat "$prompt_txt" 2>/dev/null || echo '')"

# ─── B1: override section + marker land in the pre-redaction prompt ──────────
assert_contains "B1 prompt has override delimiter" \
    "$prompt_body" "## Project-specific guidance (operator override)"
assert_contains "B1 prompt has override marker" "$prompt_body" "BUILD_OV_MARKER"

# ─── B2: override delimiter appears AFTER the core-contract anchor ───────────
# A stable build-prompt anchor is the INSTRUCTIONS section header. The override
# must be appended after the contract, never before/inside it.
delim_line="$(grep -n '## Project-specific guidance (operator override)' "$prompt_txt" | head -1 | cut -d: -f1)"
anchor_line="$(grep -n '## INSTRUCTIONS' "$prompt_txt" | head -1 | cut -d: -f1)"
if [[ -n "$delim_line" && -n "$anchor_line" && "$delim_line" -gt "$anchor_line" ]]; then
    assert_pass "B2 override delimiter ($delim_line) after INSTRUCTIONS anchor ($anchor_line)"
else
    assert_fail "B2 override delimiter after INSTRUCTIONS anchor" \
        "delim=$delim_line anchor=$anchor_line"
fi

# Secondary ordering proof against the loop-completion sentinel (also stable).
loop_line="$(grep -n 'LOOP_COMPLETE' "$prompt_txt" | head -1 | cut -d: -f1)"
if [[ -n "$delim_line" && -n "$loop_line" && "$delim_line" -gt "$loop_line" ]]; then
    assert_pass "B2b override delimiter ($delim_line) after LOOP_COMPLETE anchor ($loop_line)"
else
    assert_fail "B2b override delimiter after LOOP_COMPLETE anchor" \
        "delim=$delim_line loop=$loop_line"
fi

# ─── B3: override rides the router's redaction pass (ADR-043) ────────────────
# The plugin hands the assembled prompt file (build-prompt.txt) to
# route_to_model_loop, which redacts each iteration by construction — so the
# override being IN that file proves it is redaction-covered (the plugin no
# longer writes a separate redacted artifact).
assert_contains "B3 router-bound prompt has override marker" "$prompt_body" "BUILD_OV_MARKER"
assert_contains "B3 router-bound prompt has override delimiter" \
    "$prompt_body" "## Project-specific guidance (operator override)"

# ════════════════════════════════════════════════════════════════════════════
# WITHOUT override file — no empty-section noise, contract intact
# ════════════════════════════════════════════════════════════════════════════
rm -f "$OVERRIDE_FILE"
# Clean the prior run's artifacts so we re-render fresh.
rm -f "$prompt_txt"

run_build_inner
rc=$?
assert_eq "build inner rc=0 (no override)" "0" "$rc"

prompt_body_no="$(cat "$prompt_txt" 2>/dev/null || echo '')"

# ─── B4: no delimiter (no empty-section noise) + core contract intact ────────
if grep -qF '## Project-specific guidance (operator override)' <<< "$prompt_body_no"; then
    assert_fail "B4 no override delimiter when file absent" "delimiter leaked"
else
    assert_pass "B4 no override delimiter when file absent"
fi
assert_contains "B4 core contract intact (INSTRUCTIONS)" "$prompt_body_no" "## INSTRUCTIONS"
assert_contains "B4 core contract intact (LOOP_COMPLETE)" "$prompt_body_no" "LOOP_COMPLETE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
