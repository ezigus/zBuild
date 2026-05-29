#!/usr/bin/env bash
# Tests: build plugin assembles prompt with rendered markdown plan (#470)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build plugin prompt rendering (#470)"
setup_test_env "plugin-build-render"

# Sandbox state/events so build plugin's emits don't escape.
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# Mock the router so it never makes network calls; capture the redacted prompt
# that the build plugin passed to it.
export _MOCK_ROUTE_CAPTURE="$TEST_TEMP_DIR/route-prompt.txt"
route_to_model() {
    # $1 = tier, $2 = prompt
    printf '%s' "$2" > "$_MOCK_ROUTE_CAPTURE"
    # Return an empty diff so the build proceeds without producing a real patch.
    printf ''
    return 0
}
export -f route_to_model 2>/dev/null || true

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
# Re-override after sourcing (plugin.sh sources route.sh which provides the
# real route_to_model — our shadow must come last).
route_to_model() {
    printf '%s' "$2" > "$_MOCK_ROUTE_CAPTURE"
    printf ''
    return 0
}

# Stub apply_scope_redaction to be pass-through (no manifest required).
apply_scope_redaction() {
    local in="$1" out="$2"
    cp "$in" "$out"
    return 0
}

# ── Fixture plan.json — markdown rendering will produce a # Plan: heading ──
artifact_dir="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$artifact_dir"
plan_path="$artifact_dir/plan.json"
cat > "$plan_path" <<'EOF'
{
  "title": "Test plan",
  "goal": "Verify markdown rendering",
  "steps": [
    {"id": 1, "description": "step one", "files": ["a.sh"]}
  ]
}
EOF

scope_manifest="$TEST_TEMP_DIR/state/scope-manifest.md"
touch "$scope_manifest"

# ── Run the inner build function ──
set +e
_build_stage_run_inner \
    "$scope_manifest" \
    "$plan_path" \
    "$artifact_dir/diff.patch" \
    "$artifact_dir/build-summary.json" \
    "$artifact_dir" >/dev/null 2>&1
rc=$?
set -e

# ─── IB1: build inner returns 0 with mocked router ───────────────────────────
assert_eq "IB1 build inner rc=0 with empty diff" "0" "$rc"

# ─── IB2: captured prompt contains markdown heading, not raw JSON ────────────
captured="$(cat "$_MOCK_ROUTE_CAPTURE" 2>/dev/null || echo '')"
assert_contains "IB2 prompt has markdown plan heading" "$captured" "# Plan: Test plan"
assert_contains "IB2 prompt has rendered Goal field" "$captured" "**Goal:** Verify markdown rendering"

# ─── IB3: raw JSON shape is NOT in the prompt ────────────────────────────────
if printf '%s' "$captured" | grep -qF '"title": "Test plan"'; then
    assert_fail "IB3 raw plan.json content not in prompt" "raw JSON leaked"
else
    assert_pass "IB3 raw plan.json content not in prompt"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
