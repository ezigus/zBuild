#!/usr/bin/env bash
# Tests: --platform-override and --scope CLI flags (issue #202)
# Covers: detect_platforms short-circuit, scope-manifest.md generation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "CLI --platform-override and --scope flags (issue #202)"

setup_test_env "cli-platform-scope-flags"

STATE_DIR="$TEST_TEMP_DIR/state"
REPO_DIR="$TEST_TEMP_DIR/repo"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$STATE_DIR" "$REPO_DIR" "$TEST_TEMP_DIR/events" "$TEST_TEMP_DIR/plugins"

# Source the detect module directly for unit-level tests
source "$REPO_ROOT/core/detect/platforms.sh"

# ─── Test 1: --platform-override short-circuits detection ────────────────────
# With ZBUILD_PLATFORM_OVERRIDE set, detect_platforms must return only that value.
export ZBUILD_PLATFORM_OVERRIDE="ios"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains "ZBUILD_PLATFORM_OVERRIDE=ios → output contains ios" "$result" "ios"
if echo "$result" | grep -qF "generic"; then
    assert_fail "override set: generic should NOT appear"
else
    assert_pass "override set: generic does not appear"
fi
line_count="$(echo "$result" | grep -c . || true)"
assert_eq "override produces exactly one platform line" "1" "$line_count"
unset ZBUILD_PLATFORM_OVERRIDE
rm -f "$STATE_DIR/platforms.json"

# ─── Test 2: platforms.json written with single platform on override ──────────
export ZBUILD_PLATFORM_OVERRIDE="ios"
detect_platforms "$REPO_DIR" "$STATE_DIR" >/dev/null 2>&1
assert_file_exists "platforms.json written when override is set" "$STATE_DIR/platforms.json"
json_content="$(cat "$STATE_DIR/platforms.json")"
assert_json_key "platforms.json schema_version is 1" "$json_content" ".schema_version" "1"
detected="$(echo "$json_content" | jq -r '.detected[]' 2>/dev/null)"
assert_eq "detected array contains only override platform" "ios" "$detected"
unset ZBUILD_PLATFORM_OVERRIDE
rm -f "$STATE_DIR/platforms.json"

# ─── Test 3: override works for an arbitrary platform name ───────────────────
export ZBUILD_PLATFORM_OVERRIDE="android"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains "ZBUILD_PLATFORM_OVERRIDE=android → output contains android" "$result" "android"
line_count="$(echo "$result" | grep -c . || true)"
assert_eq "android override produces exactly one platform line" "1" "$line_count"
unset ZBUILD_PLATFORM_OVERRIDE
rm -f "$STATE_DIR/platforms.json"

# ─── Test 4: --scope path appended to scope-manifest.md ──────────────────────
scope_manifest="$STATE_DIR/scope-manifest.md"
rm -f "$scope_manifest"
scope_input="src/"
{
    echo "# Scope Manifest"
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "$scope_input"
} >> "$scope_manifest"
assert_file_exists "scope-manifest.md created" "$scope_manifest"
manifest_content="$(cat "$scope_manifest")"
assert_contains "scope-manifest.md contains src/" "$manifest_content" "src/"
rm -f "$scope_manifest"

# ─── Test 5: Multiple scope paths all appear in scope-manifest.md ────────────
scope_manifest="$STATE_DIR/scope-manifest.md"
rm -f "$scope_manifest"
{
    echo "# Scope Manifest"
    echo ""
    echo "src/"
    echo "lib/"
    echo "tests/"
} >> "$scope_manifest"
manifest_content="$(cat "$scope_manifest")"
assert_contains "scope-manifest.md contains src/" "$manifest_content" "src/"
assert_contains "scope-manifest.md contains lib/" "$manifest_content" "lib/"
assert_contains "scope-manifest.md contains tests/" "$manifest_content" "tests/"
rm -f "$scope_manifest"

# ─── Test 6: Both flags together — override + scope both work ────────────────
rm -f "$STATE_DIR/platforms.json"
scope_manifest="$STATE_DIR/scope-manifest.md"
rm -f "$scope_manifest"

export ZBUILD_PLATFORM_OVERRIDE="node"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains "combined: platform override returns node" "$result" "node"
unset ZBUILD_PLATFORM_OVERRIDE

{
    echo "# Scope Manifest"
    echo ""
    echo "src/"
} >> "$scope_manifest"
assert_file_exists "combined: scope-manifest.md exists" "$scope_manifest"
combined_content="$(cat "$scope_manifest")"
assert_contains "combined: scope-manifest.md contains src/" "$combined_content" "src/"

rm -f "$STATE_DIR/platforms.json"
rm -f "$scope_manifest"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
