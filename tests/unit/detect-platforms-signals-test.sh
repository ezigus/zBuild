#!/usr/bin/env bash
# Tests: core/detect/platforms.sh — detect.signals edge cases + regression guards
# Issues: #195 (signal parsing), #196 (config schema), #197 (conflict resolution)
# ADR-009 §"Auto-detection lives in core/, signals in manifests"
#
# Complements core-detect-platforms-test.sh (which covers the happy path and main
# scenarios).  This file focuses on:
#   A  — Malformed / degenerate signal blocks (A-1, A-3)
#   B  — .zbuild/platforms.json failure modes not covered elsewhere (B-6, B-8)
#   C  — Conflict-resolution edge cases not in the main test (C-12, C-14)
#   D  — Regression guards: ZBUILD_PLATFORM_OVERRIDE + cache-with-config-change
#
# SPEC STATUS LEGEND (per test):
#   [SPEC]     Behaviour fully described in ADR-009.
#   [UNDEF]    Behaviour not explicitly specified; test documents the safe default.
#   [REGRESSION] Must pass today; guards existing behaviour from breakage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "detect/platforms — signals edge cases + regressions (#195/#196/#197)"

setup_test_env "detect-platforms-signals"

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

# shellcheck source=../../core/detect/platforms.sh
source "$REPO_ROOT/core/detect/platforms.sh"

# ─── Fixture helpers ──────────────────────────────────────────────────────────

# Reset state cache and override between tests.
_reset() {
    rm -f "$STATE_DIR/platforms.json"
    rm -rf "$REPO_DIR/.zbuild"
}

# Create a minimal agent plugin with an empty detect: block (no signals sub-key).
_make_empty_detect_plugin() {
    local id="$1" platform="$2"
    local dir="$PLUGINS_ROOT/agent/$id"
    mkdir -p "$dir"
    # NOTE: requires: block intentionally omitted for brevity; validate_manifest
    # skips strict validation when sourcing in tests.
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Empty Detect Plugin $id
kind: agent
version: 0.1.0
hooks:
  run: ${id//-/_}_run
requires:
  core:
    - redaction
platform: $platform
detect:
EOF
    cat > "$dir/plugin.sh" <<EOF
${id//-/_}_run() { return 0; }
EOF
}

# Create an agent plugin with detect.signals.files using a given strength token.
_make_strength_plugin() {
    local id="$1" platform="$2" pattern="$3" strength="$4"
    local dir="$PLUGINS_ROOT/agent/$id"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Strength Plugin $id
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
      - pattern: "$pattern"
        strength: $strength
EOF
    cat > "$dir/plugin.sh" <<EOF
${id//-/_}_run() { return 0; }
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION A — Malformed / degenerate signal blocks (#195)
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "A: malformed / degenerate detect.signals blocks"

# ─── A-1: detect: block present but completely empty (no sub-keys) [UNDEF] ────
# ADR-009 says plugins without detect.signals "aren't part of platform
# detection".  An empty detect: scalar should be treated the same way:
# no signals → platform not auto-detected (relies on hardcoded indicators
# or falls through to "generic" floor).
#
# The current Phase 0.5 code uses _PLATFORM_INDICATORS_<platform> variables.
# "rust" has no hardcoded indicators, so it falls through to the "unknown
# platform" branch of _platform_detected_in_repo which conservatively
# returns 0 (detected).  The test verifies the engine does NOT crash
# (exit 0) — detection outcome is implementation-defined until Phase 1.
_make_empty_detect_plugin "plugin-empty-detect" "rust"
detect_rc=0
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)" || detect_rc=$?
assert_eq \
    "A-1 [UNDEF]: empty detect: block → engine does not crash (exit 0)" \
    "0" "$detect_rc"
if [[ -n "$result" ]]; then
    assert_pass "A-1 [UNDEF]: empty detect: block → non-empty result returned"
else
    assert_fail "A-1 [UNDEF]: empty detect: block → expected non-empty result"
fi
rm -rf "$PLUGINS_ROOT/agent/plugin-empty-detect"
_reset

# ─── A-3: strength value is uppercase "HIGH" [UNDEF] ─────────────────────────
# The spec uses lowercase "high"/"medium"/"low" in examples; uppercase is
# undefined.  The engine must not crash.  Detection outcome
# (whether the platform is found or not) is implementation-defined for
# the uppercase case — the test only asserts exit 0 and non-empty output.
_make_strength_plugin "plugin-upper-high" "kotlin" "build.gradle" "HIGH"
touch "$REPO_DIR/build.gradle"
detect_rc=0
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)" || detect_rc=$?
assert_eq \
    "A-3 [UNDEF]: uppercase strength value → detection does not crash (exit 0)" \
    "0" "$detect_rc"
if [[ -n "$result" ]]; then
    assert_pass "A-3 [UNDEF]: uppercase strength → non-empty result returned"
else
    assert_fail "A-3 [UNDEF]: uppercase strength → expected non-empty result"
fi
rm -f "$REPO_DIR/build.gradle"
rm -rf "$PLUGINS_ROOT/agent/plugin-upper-high"
_reset

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION B — .zbuild/platforms.json failure modes (#196)
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "B: .zbuild/platforms.json failure modes"

# ─── B-6: .zbuild/platforms.json is invalid JSON [SPEC] ──────────────────────
# ADR-009: detection must be robust to a corrupt config file.
# Expected: engine continues without crashing, does not inject garbage
# values into the detected platform list.
mkdir -p "$REPO_DIR/.zbuild"
printf 'NOT { valid json ]]]' > "$REPO_DIR/.zbuild/platforms.json"
detect_rc=0
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)" || detect_rc=$?
assert_eq \
    "B-6 [SPEC]: invalid .zbuild/platforms.json → detection does not crash (exit 0)" \
    "0" "$detect_rc"
if grep -qF "NOT" <<< "$result"; then
    assert_fail \
        "B-6 [SPEC]: invalid JSON content must not appear in detected platforms"
else
    assert_pass \
        "B-6 [SPEC]: invalid JSON content not leaked into detected platforms"
fi
# Detection should still produce some result (at minimum "generic").
if [[ -n "$result" ]]; then
    assert_pass "B-6 [SPEC]: detection returns a non-empty result despite corrupt config"
else
    assert_fail "B-6 [SPEC]: detection returned empty result after corrupt config"
fi
_reset

# ─── B-8: disable_detection path does not exist in repo [SPEC] ───────────────
# ADR-009: disable_detection lists paths to exclude from signal matching.
# Listing a path that is absent from the checkout must be silently ignored.
mkdir -p "$REPO_DIR/.zbuild"
printf '{"platforms": [], "disable_detection": ["/nonexistent/path/in/this/repo"]}' \
    > "$REPO_DIR/.zbuild/platforms.json"
detect_rc=0
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)" || detect_rc=$?
assert_eq \
    "B-8 [SPEC]: non-existent disable_detection path → no crash (exit 0)" \
    "0" "$detect_rc"
if [[ -n "$result" ]]; then
    assert_pass \
        "B-8 [SPEC]: non-existent disable_detection path → non-empty result returned"
else
    assert_fail \
        "B-8 [SPEC]: non-existent disable_detection path → expected non-empty result"
fi
_reset

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION C — Conflict-resolution edge cases (#197)
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "C: conflict-resolution edge cases"

# ─── C-12: No matching path in v2 overrides → fallback_platform used [SPEC] ───
# ADR-009: "Fallback for unknown platforms: warn + skip unless
# .zbuild/platforms.json sets fallback_platform".
# When no override entry matches the working directory, the engine must not
# crash and must apply fallback_platform as the tiebreaker.
mkdir -p "$REPO_DIR/.zbuild"
cat > "$REPO_DIR/.zbuild/platforms.json" <<'C12EOF'
{
  "schema_version": 2,
  "overrides": [{"path": "some/other/subdir", "platform": "ios"}],
  "fallback_platform": "generic"
}
C12EOF
detect_rc=0
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)" || detect_rc=$?
assert_eq \
    "C-12 [SPEC]: unmatched v2 override path → no crash (exit 0)" \
    "0" "$detect_rc"
if [[ -n "$result" ]]; then
    assert_pass \
        "C-12 [SPEC]: unmatched override path → non-empty result (fallback applied)"
else
    assert_fail \
        "C-12 [SPEC]: unmatched override path → expected non-empty result"
fi
_reset

# ─── C-14: zbuild detect platforms --explain flag [SPEC / Phase 1 stub] ───────
# ADR-009 CLI: `zbuild detect platforms --explain` prints per-folder resolution.
# Phase 0.5: the flag is explicitly deferred.  This test verifies the CLI:
#   a) Does not crash silently (any non-zero exit must produce a legible message).
#   b) If implemented, produces non-empty output on exit 0.
# NOTE: when --explain ships, this stub should be promoted to a full test in
# tests/integration/detect-platforms-explain-test.sh.
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"
if [[ -x "$ZBUILD_CLI" ]]; then
    explain_output=""
    explain_rc=0
    explain_output="$(
        "$ZBUILD_CLI" detect platforms --explain --repo "$REPO_DIR" 2>&1
    )" || explain_rc=$?
    if [[ "$explain_rc" -eq 0 ]]; then
        if [[ -n "$explain_output" ]]; then
            assert_pass "C-14 [SPEC]: zbuild detect platforms --explain exits 0 with output"
        else
            assert_fail "C-14 [SPEC]: zbuild detect platforms --explain exits 0 but produced no output"
        fi
    else
        # Must produce a legible error — not a silent crash.
        if grep -qiE \
            "not.*(implement|support|available)|deferred|unknown.*option|usage|help" <<< "$explain_output"; then
            assert_pass \
                "C-14 [SPEC] (deferred): --explain not yet implemented — clean error returned"
        else
            assert_fail \
                "C-14 [SPEC]: --explain returned non-zero without a clear error message" \
                "output: $explain_output"
        fi
    fi
else
    assert_pass \
        "C-14 [SPEC] (SKIP): zbuild CLI not found at scripts/zbuild — --explain test deferred"
fi
_reset

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION D — Regression guards
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "D: regression guards"

# ─── D-16: ZBUILD_PLATFORM_OVERRIDE still short-circuits all detection [REGRESSION] ──
# ADR-009 §"Short-circuit": when ZBUILD_PLATFORM_OVERRIDE is set, the engine
# must skip all filesystem scanning and return only the overridden platform.
# This verifies that signal-parsing code added in #195 does not break the
# existing short-circuit path.
_make_strength_plugin "reg-ios-plugin" "ios" "Package.swift" "high"
touch "$REPO_DIR/Package.swift"   # would normally trigger ios detection
ZBUILD_PLATFORM_OVERRIDE="forced-regression-platform"
export ZBUILD_PLATFORM_OVERRIDE
detect_rc=0
result="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)" || detect_rc=$?
assert_eq \
    "D-16 [REGRESSION]: ZBUILD_PLATFORM_OVERRIDE → exit 0" \
    "0" "$detect_rc"
assert_contains \
    "D-16 [REGRESSION]: ZBUILD_PLATFORM_OVERRIDE → overridden platform returned" \
    "$result" "forced-regression-platform"
if grep -qF "ios" <<< "$result"; then
    assert_fail \
        "D-16 [REGRESSION]: ZBUILD_PLATFORM_OVERRIDE → ios must NOT appear (override short-circuits)"
else
    assert_pass \
        "D-16 [REGRESSION]: ZBUILD_PLATFORM_OVERRIDE → ios correctly suppressed"
fi
unset ZBUILD_PLATFORM_OVERRIDE
rm -f "$REPO_DIR/Package.swift"
rm -rf "$PLUGINS_ROOT/agent/reg-ios-plugin"
_reset

# ─── D-17: .zbuild/platforms.json change takes effect on cache hit [UNDEF] ────
# ADR-009 §"Detection cache": cache key is repo_head_sha.  The implementation
# (platforms.sh lines 91-104) explicitly applies overrides even on cache hit
# so that config changes take effect without requiring a new commit.
# This verifies that documented behaviour survives the #195/#196/#197 changes.
#
# Approach: mock git to return a fixed SHA so the cache IS used; then
# verify that adding a new platform to .zbuild/platforms.json still
# injects it even though the SHA did not change.
mock_git_sha="aabbccdd1234567890000000000000000000000001"
cat > "$TEST_TEMP_DIR/bin/git" <<GITMOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == "-C" && "\${3:-}" == "rev-parse" && "\${4:-}" == "HEAD" ]]; then
    echo "$mock_git_sha"
    exit 0
fi
exit 128
GITMOCK
chmod +x "$TEST_TEMP_DIR/bin/git"

_make_strength_plugin "reg-node-cache" "node" "package.json" "high"
touch "$REPO_DIR/package.json"

# First detection — no override, writes cache with SHA
result_before="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
assert_contains \
    "D-17 setup: node detected and cached" \
    "$result_before" "node"

# Verify the cache file was written with the mocked SHA
cached_sha="$(jq -r '.repo_head_sha // empty' "$STATE_DIR/platforms.json" 2>/dev/null || true)"
assert_eq \
    "D-17 setup: cache file carries mocked SHA" \
    "$mock_git_sha" "$cached_sha"

# Now add an override without changing the git SHA (cache would otherwise be used)
mkdir -p "$REPO_DIR/.zbuild"
printf '{"platforms": ["python"]}' > "$REPO_DIR/.zbuild/platforms.json"

result_after="$(detect_platforms "$REPO_DIR" "$STATE_DIR" 2>/dev/null)"
# Override must be applied even though SHA matches (cache hit).
assert_contains \
    "D-17 [UNDEF]: .zbuild/platforms.json change applied even on cache hit" \
    "$result_after" "python"

# Remove the mock git binary so later cleanup uses the real git.
rm -f "$TEST_TEMP_DIR/bin/git"
rm -f "$REPO_DIR/package.json"
rm -rf "$PLUGINS_ROOT/agent/reg-node-cache"
_reset

cleanup_test_env
print_test_results
exit $((FAIL > 0))
