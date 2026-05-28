#!/usr/bin/env bash
# Tests: core/detect/platforms.sh — Platform detection engine (ADR-009) — Part B
# Covers (tests 13-23): platforms.json v2 schema (issue #196) and signal strength
#         ranking and conflict resolution (issue #197).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/detect/platforms — platform detection engine Part B (ADR-009, tests 13-23)"

setup_test_env "detect-platforms-b"

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

# ─── Helper: create a plugin with detect.signals in the manifest ──────────────
# Usage: _make_signal_plugin <id> <platform> <strength> [extra_yaml]
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

# ═══════════════════════════════════════════════════════════════════════════════
# Issue #196 — platforms.json v2 schema
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Test 13: v2 schema — overrides array injects platform ───────────────────
# .zbuild/platforms.json with an "overrides" key containing a path+platform
# entry must cause that platform to appear in the detection result.
mkdir -p "$REPO_DIR/.zbuild"
cat > "$REPO_DIR/.zbuild/platforms.json" <<'V2OVR'
{
  "schema_version": 2,
  "overrides": [
    {"path": "ios/", "platform": "ios"}
  ]
}
V2OVR
mkdir -p "$REPO_DIR/ios"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains \
    "#196: v2 overrides[].platform → platform injected" \
    "$result" "ios"
rm -f "$STATE_DIR/platforms.json"
rm -rf "$REPO_DIR/.zbuild" "$REPO_DIR/ios"

# ─── Test 14: v2 schema — disable_detection excludes matching paths ───────────
# Files inside a path listed in "disable_detection" must not contribute signal
# matches; detection must treat that subtree as invisible.
_make_signal_plugin "sig-node-dis" "node" "high"
mkdir -p "$REPO_DIR/legacy"
touch "$REPO_DIR/legacy/package.json"
mkdir -p "$REPO_DIR/.zbuild"
cat > "$REPO_DIR/.zbuild/platforms.json" <<'V2DIS'
{
  "schema_version": 2,
  "disable_detection": ["legacy/"]
}
V2DIS
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
if ! echo "$result" | grep -qF "node"; then
    assert_pass \
        "#196: disable_detection path → indicator files inside excluded subtree not counted"
else
    assert_fail \
        "#196: disable_detection path → indicator files inside excluded subtree not counted" \
        "node appeared despite path being in disable_detection list"
fi
rm -f "$STATE_DIR/platforms.json"
rm -rf "$REPO_DIR/.zbuild" "$REPO_DIR/legacy"
rm -rf "$PLUGINS_ROOT/agent/sig-node-dis"

# ─── Test 15: v2 schema — aliases resolves platform name ──────────────────────
# An "aliases" map of {"nodejs": "node"} means a plugin declaring platform
# "nodejs" should be treated as "node" after alias resolution.
ALIAS_PLUGIN_DIR="$PLUGINS_ROOT/agent/sig-nodejs-alias"
mkdir -p "$ALIAS_PLUGIN_DIR"
cat > "$ALIAS_PLUGIN_DIR/manifest.yaml" <<'ALPEOF'
id: sig-nodejs-alias
name: NodeJS Alias Plugin
kind: agent
version: 0.1.0
hooks:
  run: sig_nodejs_alias_run
requires:
  core:
    - redaction
platform: nodejs
detect:
  signals:
    files:
      - pattern: "package.json"
        strength: high
ALPEOF
cat > "$ALIAS_PLUGIN_DIR/plugin.sh" <<'ALPEOF'
sig_nodejs_alias_run() { return 0; }
ALPEOF
mkdir -p "$REPO_DIR/.zbuild"
cat > "$REPO_DIR/.zbuild/platforms.json" <<'V2ALIAS'
{
  "schema_version": 2,
  "aliases": {"nodejs": "node"}
}
V2ALIAS
touch "$REPO_DIR/package.json"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains \
    "#196: aliases.nodejs → resolves to node in output" \
    "$result" "node"
rm -f "$STATE_DIR/platforms.json" "$REPO_DIR/package.json"
rm -rf "$REPO_DIR/.zbuild" "$ALIAS_PLUGIN_DIR"

# ─── Test 16: v2 schema — fallback_platform used when detection is empty ──────
# When no signals match and no other overrides are present, "fallback_platform"
# in .zbuild/platforms.json must supply the final result instead of "generic".
mkdir -p "$REPO_DIR/.zbuild"
cat > "$REPO_DIR/.zbuild/platforms.json" <<'V2FBACK'
{
  "schema_version": 2,
  "fallback_platform": "python"
}
V2FBACK
# No plugins, no indicator files — engine should use fallback_platform
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains \
    "#196: fallback_platform used when nothing detected" \
    "$result" "python"
rm -f "$STATE_DIR/platforms.json"
rm -rf "$REPO_DIR/.zbuild"

# ─── Test 17: v2 schema — cost_overrides field parsed without error ───────────
# A platforms.json containing a "cost_overrides" key must not cause the engine
# to fail, crash, or produce an error message. Validation test only.
mkdir -p "$REPO_DIR/.zbuild"
cat > "$REPO_DIR/.zbuild/platforms.json" <<'V2COST'
{
  "schema_version": 2,
  "cost_overrides": {
    "ios":  {"max_tokens_per_stage": 200000},
    "node": {"max_tokens_per_stage": 100000}
  }
}
V2COST
detect_exit=0
detect_platforms "$REPO_DIR" "$STATE_DIR" >/dev/null 2>/dev/null || detect_exit=$?
assert_eq \
    "#196: cost_overrides field → engine exits 0 (parsed without error)" \
    "0" "$detect_exit"
rm -f "$STATE_DIR/platforms.json"
rm -rf "$REPO_DIR/.zbuild"

# ─── Test 18: v2 schema — legacy {"platforms": [...]} format still works ──────
# Backward compatibility: a .zbuild/platforms.json using the v1 shape must
# still inject its listed platforms (already covered by test 7, repeated here
# against the v2 code path to guard regressions during schema migration).
mkdir -p "$REPO_DIR/.zbuild"
cat > "$REPO_DIR/.zbuild/platforms.json" <<'V1LEGACY'
{"platforms": ["python"]}
V1LEGACY
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains \
    "#196: legacy v1 platforms[] format → still injects platform (backward compat)" \
    "$result" "python"
rm -f "$STATE_DIR/platforms.json"
rm -rf "$REPO_DIR/.zbuild"

# ═══════════════════════════════════════════════════════════════════════════════
# Issue #197 — Signal strength ranking and conflict resolution
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Test 19: higher strength sum wins when two platforms match ───────────────
# If ios has two "high" signals matched and node has one "low" signal matched,
# ios must win the single-platform selection when the engine must pick one.
# (Only meaningful once the engine enforces strength-based ranking.)
_make_swift_signal_plugin "sig-ios-strong" "ios" "high"
_make_signal_plugin "sig-node-weak" "node" "low"
touch "$REPO_DIR/Package.swift"
touch "$REPO_DIR/package.json"
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
# Both may be present in a multi-platform scenario; the important invariant is
# that ios appears and the result is not empty.
assert_contains \
    "#197: higher strength sum → ios present in result" \
    "$result" "ios"
rm -f "$STATE_DIR/platforms.json" "$REPO_DIR/Package.swift" "$REPO_DIR/package.json"
rm -rf "$PLUGINS_ROOT/agent/sig-ios-strong" "$PLUGINS_ROOT/agent/sig-node-weak"

# ─── Test 20: tie in strength → detection.conflict event emitted ─────────────
# When two platforms have equal signal strength sums and no override resolves
# the tie, the engine must emit a "detection.conflict" event to the event bus.
: > "$ZBUILD_EVENTS_JSONL"
_make_swift_signal_plugin "sig-ios-tie" "ios" "high"
_make_signal_plugin "sig-node-tie" "node" "high"
touch "$REPO_DIR/Package.swift"
touch "$REPO_DIR/package.json"
detect_platforms "$REPO_DIR" "$STATE_DIR" >/dev/null 2>/dev/null || true
if grep -qF "detection.conflict" "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "#197: equal-strength tie → detection.conflict event emitted"
else
    assert_fail "#197: equal-strength tie → detection.conflict event emitted" \
        "no detection.conflict in events.jsonl"
fi
rm -f "$STATE_DIR/platforms.json" "$REPO_DIR/Package.swift" "$REPO_DIR/package.json"
rm -rf "$PLUGINS_ROOT/agent/sig-ios-tie" "$PLUGINS_ROOT/agent/sig-node-tie"

# ─── Test 21: tie + override in config → override wins, no conflict event ─────
# When a tie occurs but .zbuild/platforms.json has an override that pins one
# platform to a path, the override must resolve the conflict without emitting
# a "detection.conflict" event.
: > "$ZBUILD_EVENTS_JSONL"
_make_swift_signal_plugin "sig-ios-ov" "ios" "high"
_make_signal_plugin "sig-node-ov" "node" "high"
touch "$REPO_DIR/Package.swift"
touch "$REPO_DIR/package.json"
mkdir -p "$REPO_DIR/.zbuild"
cat > "$REPO_DIR/.zbuild/platforms.json" <<'OVRTIE'
{
  "schema_version": 2,
  "overrides": [{"path": ".", "platform": "ios"}]
}
OVRTIE
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains \
    "#197: tie + override → override wins (ios in result)" \
    "$result" "ios"
if ! grep -qF "detection.conflict" "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass \
        "#197: tie + override → no detection.conflict event emitted"
else
    assert_fail \
        "#197: tie + override → no detection.conflict event emitted" \
        "detection.conflict was emitted despite override being present"
fi
rm -f "$STATE_DIR/platforms.json" "$REPO_DIR/Package.swift" "$REPO_DIR/package.json"
rm -rf "$REPO_DIR/.zbuild"
rm -rf "$PLUGINS_ROOT/agent/sig-ios-ov" "$PLUGINS_ROOT/agent/sig-node-ov"

# ─── Test 22: tie + fallback_platform → fallback wins with warning ────────────
# When a tie occurs with no path override, but "fallback_platform" is set in
# .zbuild/platforms.json, the fallback must be used and a warning must appear
# on stderr (or as an event); the result must NOT be empty.
: > "$ZBUILD_EVENTS_JSONL"
_make_swift_signal_plugin "sig-ios-fb" "ios" "high"
_make_signal_plugin "sig-node-fb" "node" "high"
touch "$REPO_DIR/Package.swift"
touch "$REPO_DIR/package.json"
mkdir -p "$REPO_DIR/.zbuild"
cat > "$REPO_DIR/.zbuild/platforms.json" <<'FBTIE'
{
  "schema_version": 2,
  "fallback_platform": "ios"
}
FBTIE
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains \
    "#197: tie + fallback_platform → fallback platform in result" \
    "$result" "ios"
rm -f "$STATE_DIR/platforms.json" "$REPO_DIR/Package.swift" "$REPO_DIR/package.json"
rm -rf "$REPO_DIR/.zbuild"
rm -rf "$PLUGINS_ROOT/agent/sig-ios-fb" "$PLUGINS_ROOT/agent/sig-node-fb"

# ─── Test 23: tie + no override + no fallback → folder marked ambiguous ───────
# When a tie occurs with no override and no fallback_platform configured, the
# engine must not crash or silently drop both platforms. The result must contain
# both tied platforms (or a sentinel "ambiguous" marker, per implementation),
# and a detection.conflict event must be recorded.
: > "$ZBUILD_EVENTS_JSONL"
_make_swift_signal_plugin "sig-ios-amb" "ios" "high"
_make_signal_plugin "sig-node-amb" "node" "high"
touch "$REPO_DIR/Package.swift"
touch "$REPO_DIR/package.json"
# No .zbuild/platforms.json — no override, no fallback
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
detect_exit=$?
assert_eq \
    "#197: tie, no override, no fallback → engine does not crash (exit 0)" \
    "0" "$detect_exit"
# Either both platforms appear (multi-platform output) or an "ambiguous" marker
if echo "$result" | grep -qF "ios" && echo "$result" | grep -qF "node"; then
    assert_pass \
        "#197: tie, no override, no fallback → both platforms present in output"
elif echo "$result" | grep -qF "ambiguous"; then
    assert_pass \
        "#197: tie, no override, no fallback → ambiguous marker in output"
else
    assert_fail \
        "#197: tie, no override, no fallback → both platforms or ambiguous marker in output" \
        "got: $result"
fi
if grep -qF "detection.conflict" "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "#197: tie, no override, no fallback → detection.conflict event present"
else
    assert_fail "#197: tie, no override, no fallback → detection.conflict event present" \
        "no detection.conflict in events.jsonl"
fi
rm -f "$STATE_DIR/platforms.json" "$REPO_DIR/Package.swift" "$REPO_DIR/package.json"
rm -rf "$PLUGINS_ROOT/agent/sig-ios-amb" "$PLUGINS_ROOT/agent/sig-node-amb"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
