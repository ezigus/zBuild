#!/usr/bin/env bash
# Tests: core/detect/platforms.sh — Platform detection engine (ADR-009) — Part A
# Covers (tests 1-12): basic platform detection, indicator files, platform.json
#         written to state dir, idempotency, override file, and detect.signals
#         from manifest (issues #195).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/detect/platforms — platform detection engine Part A (ADR-009, tests 1-12)"

setup_test_env "detect-platforms-a"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
REPO_DIR="$TEST_TEMP_DIR/repo"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$PLUGINS_ROOT" "$STATE_DIR" "$REPO_DIR" "$TEST_TEMP_DIR/events"

# shellcheck source=../core/detect/platforms.sh
source "$REPO_ROOT/core/detect/platforms.sh"

# ─── Helper: create a plugin with a platform field ───────────────────────────
_make_platform_plugin() {
    local id="$1" platform="$2"
    local dir="$PLUGINS_ROOT/agent/$id"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Platform Plugin $id
kind: agent
version: 0.1.0
hooks:
  run: ${id//-/_}_run
requires:
  core:
    - redaction
platform: $platform
EOF
    cat > "$dir/plugin.sh" <<EOF
${id//-/_}_run() { return 0; }
EOF
}

# ─── Test 1: No plugins with platform → returns generic ──────────────────────
# No plugins at all; detect should fall back to "generic"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains "no plugins → output contains generic" "$result" "generic"

# Reset state dir between tests to avoid cache hits (no git SHA in REPO_DIR)
rm -f "$STATE_DIR/platforms.json"

# ─── Test 2: Platform plugin declared but no indicator files → generic ────────
_make_platform_plugin "security-lens-ios" "ios"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains "ios plugin declared but no indicator files → generic" "$result" "generic"
if echo "$result" | grep -qF "ios"; then
    assert_fail "ios should NOT appear when no indicator files present"
else
    assert_pass "ios not returned when indicator files absent"
fi

rm -f "$STATE_DIR/platforms.json"
# Remove the ios plugin so it doesn't interfere with later tests
rm -rf "$PLUGINS_ROOT/agent/security-lens-ios"

# ─── Test 3: Platform indicator file present → platform detected ──────────────
_make_platform_plugin "security-lens-ios" "ios"
touch "$REPO_DIR/Package.swift"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains "Package.swift present → ios detected" "$result" "ios"

rm -f "$STATE_DIR/platforms.json"
rm -f "$REPO_DIR/Package.swift"
rm -rf "$PLUGINS_ROOT/agent/security-lens-ios"

# ─── Test 4: Multiple platforms detected ─────────────────────────────────────
_make_platform_plugin "security-lens-ios" "ios"
_make_platform_plugin "security-lens-node" "node"
touch "$REPO_DIR/Package.swift"
touch "$REPO_DIR/package.json"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains "ios detected with both indicators present" "$result" "ios"
assert_contains "node detected with both indicators present" "$result" "node"

rm -f "$STATE_DIR/platforms.json"
rm -f "$REPO_DIR/Package.swift"
rm -f "$REPO_DIR/package.json"
rm -rf "$PLUGINS_ROOT/agent/security-lens-ios"
rm -rf "$PLUGINS_ROOT/agent/security-lens-node"

# ─── Test 5: platforms.json written to state dir ─────────────────────────────
_make_platform_plugin "security-lens-ios" "ios"
touch "$REPO_DIR/Package.swift"
detect_platforms "$REPO_DIR" "$STATE_DIR" >/dev/null 2>&1
assert_file_exists "platforms.json written to state dir" "$STATE_DIR/platforms.json"

# Check schema_version: 1
json_content="$(cat "$STATE_DIR/platforms.json")"
assert_json_key "platforms.json has schema_version 1" "$json_content" ".schema_version" "1"
assert_contains "platforms.json has detected array" "$json_content" "detected"

rm -f "$STATE_DIR/platforms.json"
rm -f "$REPO_DIR/Package.swift"
rm -rf "$PLUGINS_ROOT/agent/security-lens-ios"

# ─── Test 6: Idempotent — two runs return the same result ────────────────────
# REPO_DIR is not a git repo, so SHA is empty and cache is NOT used.
# We verify the function is stable across two calls.
_make_platform_plugin "security-lens-ios" "ios"
touch "$REPO_DIR/Package.swift"
result_first="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
rm -f "$STATE_DIR/platforms.json"
result_second="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_eq "two consecutive runs return identical output" "$result_first" "$result_second"

rm -f "$STATE_DIR/platforms.json"
rm -f "$REPO_DIR/Package.swift"
rm -rf "$PLUGINS_ROOT/agent/security-lens-ios"

# ─── Test 7: Override file respected ─────────────────────────────────────────
# No python indicator files present; override file should still inject python
mkdir -p "$REPO_DIR/.zbuild"
cat > "$REPO_DIR/.zbuild/platforms.json" <<'OVERRIDE_EOF'
{"platforms": ["python"]}
OVERRIDE_EOF
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains "override file injects python platform" "$result" "python"

rm -f "$STATE_DIR/platforms.json"
rm -rf "$REPO_DIR/.zbuild"

# ─── Test 8: Node detected when package.json present ─────────────────────────
_make_platform_plugin "security-lens-node" "node"
touch "$REPO_DIR/package.json"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains "package.json present → node detected" "$result" "node"

rm -f "$STATE_DIR/platforms.json"
rm -f "$REPO_DIR/package.json"
rm -rf "$PLUGINS_ROOT/agent/security-lens-node"

# ═══════════════════════════════════════════════════════════════════════════════
# Issue #195 — Declarative detect.signals in plugin manifests
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Helper: create a plugin with detect.signals in the manifest ──────────────
# Usage: _make_signal_plugin <id> <platform> <strength> [extra_yaml]
# Creates a manifest whose detection is declared via detect.signals.files rather
# than relying on the legacy hardcoded _PLATFORM_INDICATORS_* variables.
_make_signal_plugin() {
    local id="$1" platform="$2" strength="${3:-high}"
    local extra_yaml="${4:-}"
    local dir="$PLUGINS_ROOT/agent/$id"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Signal Plugin $id
kind: agent
version: 0.1.0
hooks:
  run: ${id//-/_}_run
requires:
  core:
    - redaction
platform: $platform
detect:
  signals:
    files:
      - pattern: "package.json"
        strength: $strength
${extra_yaml}
EOF
    cat > "$dir/plugin.sh" <<EOF
${id//-/_}_run() { return 0; }
EOF
}

# ─── Helper: create a signal plugin keyed on Package.swift ───────────────────
_make_swift_signal_plugin() {
    local id="$1" platform="$2" strength="${3:-high}"
    local dir="$PLUGINS_ROOT/agent/$id"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Swift Signal Plugin $id
kind: agent
version: 0.1.0
hooks:
  run: ${id//-/_}_run
requires:
  core:
    - redaction
platform: $platform
detect:
  signals:
    files:
      - pattern: "Package.swift"
        strength: $strength
EOF
    cat > "$dir/plugin.sh" <<EOF
${id//-/_}_run() { return 0; }
EOF
}

# ─── Test 9: detect.signals.files — high-strength match → platform detected ──
# A manifest declaring detect.signals.files with pattern "package.json" and
# strength "high" must cause the platform to be detected when the file exists.
_make_signal_plugin "sig-node-high" "node" "high"
touch "$REPO_DIR/package.json"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains \
    "#195: detect.signals.files high-strength match → platform detected" \
    "$result" "node"
rm -f "$STATE_DIR/platforms.json" "$REPO_DIR/package.json"
rm -rf "$PLUGINS_ROOT/agent/sig-node-high"

# ─── Test 10: detect.signals — multiple signals, none present → not detected ─
# A manifest whose detect.signals.files patterns are absent from the repo must
# NOT produce a platform hit; output falls back to generic.
_make_signal_plugin "sig-node-nomatch" "node" "high"
# No indicator files created — repo is empty
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
if ! echo "$result" | grep -qF "node"; then
    assert_pass \
        "#195: detect.signals with no matching files → platform NOT detected"
else
    assert_fail \
        "#195: detect.signals with no matching files → platform NOT detected" \
        "node appeared when no indicator files were present"
fi
assert_contains \
    "#195: detect.signals with no matching files → fallback to generic" \
    "$result" "generic"
rm -f "$STATE_DIR/platforms.json"
rm -rf "$PLUGINS_ROOT/agent/sig-node-nomatch"

# ─── Test 11: detect.signals — strength: low match → still detected ───────────
# Any file-pattern match, regardless of strength value, must trigger detection.
# Strength is used for conflict resolution, not as a detection gate.
_make_signal_plugin "sig-node-low" "node" "low"
touch "$REPO_DIR/package.json"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains \
    "#195: detect.signals strength:low match → platform still detected" \
    "$result" "node"
rm -f "$STATE_DIR/platforms.json" "$REPO_DIR/package.json"
rm -rf "$PLUGINS_ROOT/agent/sig-node-low"

# ─── Test 12: generic-platform-marker sentinel → always outputs generic ───────
# The generic-platform-marker plugin (no detect.signals, no platform field) must
# not inject a named platform; the fallback floor produces "generic" output.
# This acts as a smoke-test for the sentinel plugin structure from issue #195.
GENERIC_MARKER_DIR="$PLUGINS_ROOT/tool/generic-platform-marker"
mkdir -p "$GENERIC_MARKER_DIR"
cat > "$GENERIC_MARKER_DIR/manifest.yaml" <<'GEOF'
id: generic-platform-marker
name: Generic Platform Marker
kind: tool
version: 0.1.0
hooks:
  run: generic_platform_marker_run
requires:
  core:
    - redaction
GEOF
cat > "$GENERIC_MARKER_DIR/plugin.sh" <<'GEOF'
generic_platform_marker_run() { return 0; }
GEOF
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains \
    "#195: generic-platform-marker present → generic in output" \
    "$result" "generic"
if ! echo "$result" | grep -vF "generic" | grep -qE '\S'; then
    assert_pass \
        "#195: generic-platform-marker only → no unexpected named platforms"
else
    assert_fail \
        "#195: generic-platform-marker only → no unexpected named platforms" \
        "unexpected named platform in output: $result"
fi
rm -f "$STATE_DIR/platforms.json"
rm -rf "$GENERIC_MARKER_DIR"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
