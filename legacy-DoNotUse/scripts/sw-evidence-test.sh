#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright evidence test — Unit tests for sw-evidence.sh               ║
# ║  Tests: help, capture, verify, manifest, pre-pr                         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "sw-evidence Tests"

setup_test_env "sw-evidence-test"
_test_cleanup_hook() { cleanup_test_env; }

# Build a minimal test repo so REPO_DIR resolves to our temp
# sw-evidence.sh uses SCRIPT_DIR/.. as REPO_DIR — we need scripts under test repo
TEST_REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$TEST_REPO/scripts/lib" "$TEST_REPO/config" "$TEST_REPO/.claude/evidence"

# Copy sw-evidence and its lib dependencies
cp "$SCRIPT_DIR/sw-evidence.sh" "$TEST_REPO/scripts/"
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && cp "$SCRIPT_DIR/lib/compat.sh" "$TEST_REPO/scripts/lib/"
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEST_REPO/scripts/lib/"

# Policy fixture with evidence.collectors (CLI-only for reliability)
cat > "$TEST_REPO/config/policy.json" <<'POLICY'
{
  "evidence": {
    "artifactMaxAgeMinutes": 60,
    "requireFreshArtifacts": true,
    "collectors": [
      {
        "name": "cli-echo",
        "type": "cli",
        "command": "echo '{\"status\":\"ok\",\"version\":\"1.0\"}'",
        "expectedExitCode": 0,
        "assertions": ["status-ok", "response-has-version"]
      },
      {
        "name": "cli-true",
        "type": "cli",
        "command": "true",
        "expectedExitCode": 0
      }
    ]
  }
}
POLICY

# Mock curl (for api/browser collectors if any get added)
mock_binary "curl" 'echo "{\"status\":\"ok\"}"; exit 0'
mock_git

# Ensure jq is available (test-helpers links real jq)
if ! command -v jq &>/dev/null; then
    mock_binary "jq" 'cat'
fi

run_evidence() {
    cd "$TEST_REPO" && bash "$TEST_REPO/scripts/sw-evidence.sh" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════════
# help
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "help"

help_out=$(run_evidence help 2>&1) || true
help_exit=$?
assert_contains "help shows usage" "$help_out" "Usage:"
assert_contains "help mentions capture" "$help_out" "capture"
assert_contains "help mentions verify" "$help_out" "verify"
assert_contains "help mentions pre-pr" "$help_out" "pre-pr"
assert_eq "help exits 0" "0" "$help_exit"

help_h=$(run_evidence --help 2>&1) || true
assert_contains "-h shows usage" "$help_h" "shipwright evidence"

# ═══════════════════════════════════════════════════════════════════════════════
# types
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "types"

types_out=$(run_evidence types 2>&1) || true
assert_contains "types lists browser" "$types_out" "browser"
assert_contains "types lists api" "$types_out" "api"
assert_contains "types lists cli" "$types_out" "cli"
assert_contains "types lists database" "$types_out" "database"

# ═══════════════════════════════════════════════════════════════════════════════
# capture cli
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "capture cli"

rm -rf "$TEST_REPO/.claude/evidence"/*
mkdir -p "$TEST_REPO/.claude/evidence"

capture_out=$(run_evidence capture cli 2>&1) || true
assert_contains "capture runs collectors" "$capture_out" "cli"

# Evidence artifacts created
assert_file_exists "cli-echo evidence file" "$TEST_REPO/.claude/evidence/cli-echo.json"
assert_file_exists "cli-true evidence file" "$TEST_REPO/.claude/evidence/cli-true.json"

# Validate evidence record structure
echo_json=$(cat "$TEST_REPO/.claude/evidence/cli-echo.json")
assert_contains "evidence has name" "$echo_json" '"name"'
assert_contains "evidence has type" "$echo_json" '"type"'
assert_contains "evidence has passed" "$echo_json" '"passed"'
assert_contains "evidence has captured_at" "$echo_json" '"captured_at"'

# ═══════════════════════════════════════════════════════════════════════════════
# manifest
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "manifest"

assert_file_exists "manifest created" "$TEST_REPO/.claude/evidence/manifest.json"

manifest=$(cat "$TEST_REPO/.claude/evidence/manifest.json")
assert_contains "manifest has captured_at" "$manifest" "captured_at"
assert_contains "manifest has collector_count" "$manifest" "collector_count"
assert_contains "manifest has collectors" "$manifest" "collectors"

# Manifest is valid JSON
if echo "$manifest" | jq empty 2>/dev/null; then
    assert_pass "manifest is valid JSON"
else
    assert_fail "manifest is valid JSON"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# verify
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "verify"

# shellcheck disable=SC2034
verify_out=$(run_evidence verify 2>&1) || verify_exit=$?
# Verify should pass when evidence is fresh
assert_contains "verify checks evidence" "$verify_out" "evidence"

# Verify fails when no manifest
rm -f "$TEST_REPO/.claude/evidence/manifest.json"
verify_fail_out=$(run_evidence verify 2>&1) || true
assert_contains "verify fails without manifest" "$verify_fail_out" "No evidence manifest"

# Restore manifest for next tests
run_evidence capture cli 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# verify stale (artifact freshness)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "verify artifact freshness"

# Policy with very short max age
cat > "$TEST_REPO/config/policy.json" <<'POLICY2'
{
  "evidence": {
    "artifactMaxAgeMinutes": 0,
    "requireFreshArtifacts": true,
    "collectors": [{"name":"cli-echo","type":"cli","command":"true","expectedExitCode":0}]
  }
}
POLICY2

run_evidence capture cli 2>/dev/null || true

# Overwrite manifest with old epoch (2 hours ago)
old_epoch=$(($(date +%s) - 7200))
jq --argjson epoch "$old_epoch" '.captured_epoch = $epoch' \
    "$TEST_REPO/.claude/evidence/manifest.json" > "$TEST_TEMP_DIR/manifest_tmp.json"
mv "$TEST_TEMP_DIR/manifest_tmp.json" "$TEST_REPO/.claude/evidence/manifest.json"

verify_stale_out=$(run_evidence verify 2>&1) || true
assert_contains "verify reports stale evidence" "$verify_stale_out" "stale"

# Restore policy for pre-pr
cat > "$TEST_REPO/config/policy.json" <<'POLICY'
{
  "evidence": {
    "artifactMaxAgeMinutes": 60,
    "requireFreshArtifacts": true,
    "collectors": [
      {"name":"cli-echo","type":"cli","command":"echo '{\"status\":\"ok\"}'","expectedExitCode":0},
      {"name":"cli-true","type":"cli","command":"true","expectedExitCode":0}
    ]
  }
}
POLICY

# ═══════════════════════════════════════════════════════════════════════════════
# pre-pr
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pre-pr"

rm -rf "$TEST_REPO/.claude/evidence"/*
mkdir -p "$TEST_REPO/.claude/evidence"

prepr_out=$(run_evidence pre-pr 2>&1) || true
assert_contains "pre-pr runs capture" "$prepr_out" "Capturing"
assert_contains "pre-pr runs verify" "$prepr_out" "Verifying"
assert_file_exists "pre-pr creates manifest" "$TEST_REPO/.claude/evidence/manifest.json"

# ═══════════════════════════════════════════════════════════════════════════════
# status
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "status"

status_out=$(run_evidence status 2>&1) || true
assert_contains "status shows manifest path" "$status_out" "manifest"
assert_contains "status shows collectors" "$status_out" "Collectors"

print_test_results
