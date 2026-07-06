#!/usr/bin/env bash
# Tests: --platform-override and --scope CLI flags (issue #202)
# Covers: detect_platforms short-circuit, scope-manifest.md generation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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
if grep -qF "generic" <<< "$result"; then
    assert_fail "override set: generic should NOT appear"
else
    assert_pass "override set: generic does not appear"
fi
line_count="$(grep -c . || true)" <<< "$result"
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
line_count="$(grep -c . || true)" <<< "$result"
assert_eq "android override produces exactly one platform line" "1" "$line_count"
unset ZBUILD_PLATFORM_OVERRIDE
rm -f "$STATE_DIR/platforms.json"

# Source the runner module to get access to write_scope_override.
# atomic_write is already available (platforms.sh sources atomic.sh transitively).
# runner.sh is guarded with [[ "${BASH_SOURCE[0]}" == "$0" ]] so sourcing it
# only loads functions without executing main().
source "$REPO_ROOT/core/pipeline/runner.sh"

# ─── Test 4: write_scope_override writes '+ <path>' format ───────────────────
rm -f "$STATE_DIR/scope-override.md"
export ZBUILD_SCOPE_PATHS="src/"
write_scope_override "$STATE_DIR" "test-run-id"
assert_file_exists "scope-override.md created by write_scope_override" "$STATE_DIR/scope-override.md"
override_content="$(cat "$STATE_DIR/scope-override.md")"
assert_contains "scope-override.md contains '+ src/'" "$override_content" "+ src/"
# Must NOT appear as a bare path without the '+' prefix (redaction contract)
if grep -qE '^src/$' "$STATE_DIR/scope-override.md" 2>/dev/null; then
    assert_fail "scope-override.md must not contain bare path without '+' prefix"
else
    assert_pass "scope-override.md has no bare path lines"
fi
unset ZBUILD_SCOPE_PATHS
rm -f "$STATE_DIR/scope-override.md"

# ─── Test 5: Multiple scope paths all get '+ <path>' entries ─────────────────
rm -f "$STATE_DIR/scope-override.md"
export ZBUILD_SCOPE_PATHS
ZBUILD_SCOPE_PATHS="$(printf '%s\n' "src/" "lib/" "tests/")"
write_scope_override "$STATE_DIR" "test-run-id"
assert_file_exists "scope-override.md created for multiple paths" "$STATE_DIR/scope-override.md"
override_content="$(cat "$STATE_DIR/scope-override.md")"
assert_contains "scope-override.md contains '+ src/'" "$override_content" "+ src/"
assert_contains "scope-override.md contains '+ lib/'" "$override_content" "+ lib/"
assert_contains "scope-override.md contains '+ tests/'" "$override_content" "+ tests/"
unset ZBUILD_SCOPE_PATHS
rm -f "$STATE_DIR/scope-override.md"

# ─── Test 6: Platform override + scope override both work independently ───────
rm -f "$STATE_DIR/platforms.json"
rm -f "$STATE_DIR/scope-override.md"

export ZBUILD_PLATFORM_OVERRIDE="node"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains "combined: platform override returns node" "$result" "node"
unset ZBUILD_PLATFORM_OVERRIDE

export ZBUILD_SCOPE_PATHS="src/"
write_scope_override "$STATE_DIR" "test-run-id"
assert_file_exists "combined: scope-override.md exists" "$STATE_DIR/scope-override.md"
combined_content="$(cat "$STATE_DIR/scope-override.md")"
assert_contains "combined: scope-override.md contains '+ src/'" "$combined_content" "+ src/"
unset ZBUILD_SCOPE_PATHS

rm -f "$STATE_DIR/platforms.json"
rm -f "$STATE_DIR/scope-override.md"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
