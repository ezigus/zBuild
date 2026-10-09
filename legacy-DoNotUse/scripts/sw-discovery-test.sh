#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright discovery test — Cross-Pipeline Real-Time Learning tests     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/discoveries"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    export SHIPWRIGHT_PIPELINE_ID="test-pipeline-001"
}

_test_cleanup_hook() { cleanup_test_env; }

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Discovery Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright discovery"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits 1" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 4: broadcast missing args ───────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" broadcast 2>&1) && rc=0 || rc=$?
assert_eq "broadcast without args exits 1" "1" "$rc"

# ─── Test 5: query missing args ───────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" query 2>&1) && rc=0 || rc=$?
assert_eq "query without args exits 1" "1" "$rc"

# ─── Test 6: inject missing args ──────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" inject 2>&1) && rc=0 || rc=$?
assert_eq "inject without args exits 1" "1" "$rc"

# ─── Test 7: broadcast a discovery ────────────────────────────────────────
echo ""
echo -e "  ${CYAN}broadcast subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" broadcast "auth-fix" "src/auth/*.ts" "JWT validation fixed" "Added claim check" 2>&1) && rc=0 || rc=$?
assert_eq "broadcast exits 0" "0" "$rc"
assert_contains "broadcast confirms" "$output" "Broadcast discovery"

# ─── Test 8: discoveries file created ─────────────────────────────────────
if [[ -f "$HOME/.shipwright/discoveries.jsonl" ]]; then
    assert_pass "discoveries.jsonl created"
else
    assert_fail "discoveries.jsonl created"
fi

# ─── Test 9: discoveries file has valid JSONL ─────────────────────────────
line=$(head -1 "$HOME/.shipwright/discoveries.jsonl" 2>/dev/null || echo "")
if echo "$line" | jq . >/dev/null 2>&1; then
    assert_pass "discoveries.jsonl contains valid JSON"
else
    assert_fail "discoveries.jsonl contains valid JSON" "line: $line"
fi

# ─── Test 10: query for matching pattern ──────────────────────────────────
echo ""
echo -e "  ${CYAN}query subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" query "src/auth/*.ts" 2>&1) && rc=0 || rc=$?
assert_eq "query exits 0" "0" "$rc"
assert_contains "query finds discovery" "$output" "auth-fix"

# ─── Test 11: query for non-matching pattern ──────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" query "nonexistent/path/*.go" 2>&1) && rc=0 || rc=$?
assert_eq "query non-match exits 0" "0" "$rc"
assert_contains "query reports no discoveries" "$output" "No relevant discoveries"

# ─── Test 12: status subcommand ───────────────────────────────────────────
echo ""
echo -e "  ${CYAN}status subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" status 2>&1) && rc=0 || rc=$?
assert_eq "status exits 0" "0" "$rc"
assert_contains "status shows total" "$output" "Total discoveries"

# ─── Test 13: clean subcommand (nothing to clean) ─────────────────────────
echo ""
echo -e "  ${CYAN}clean subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" clean 2>&1) && rc=0 || rc=$?
assert_eq "clean exits 0" "0" "$rc"
assert_contains "clean reports result" "$output" "discoveries"

# ─── Test 14: inject subcommand ───────────────────────────────────────────
echo ""
echo -e "  ${CYAN}inject subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" inject "src/auth/*.ts" 2>&1) && rc=0 || rc=$?
assert_eq "inject exits 0" "0" "$rc"

# ─── Test 15: patterns_overlap function ────────────────────────────────────
echo ""
echo -e "  ${CYAN}internal patterns_overlap${RESET}"
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-discovery.sh"

    # Same pattern should match
    if patterns_overlap "src/auth/*.ts" "src/auth/*.ts"; then
        echo "SAME_MATCH"
    else
        echo "SAME_NO_MATCH"
    fi

    # Non-overlapping should not match
    if patterns_overlap "src/auth/*.ts" "lib/db/*.go"; then
        echo "DIFF_MATCH"
    else
        echo "DIFF_NO_MATCH"
    fi
) > "$TEST_TEMP_DIR/overlap_output" 2>/dev/null
overlap_result=$(cat "$TEST_TEMP_DIR/overlap_output")
if echo "$overlap_result" | grep -qF "SAME_MATCH"; then
    assert_pass "patterns_overlap matches same pattern"
else
    assert_fail "patterns_overlap matches same pattern" "got: $overlap_result"
fi
if echo "$overlap_result" | grep -qF "DIFF_NO_MATCH"; then
    assert_pass "patterns_overlap rejects different paths"
else
    assert_fail "patterns_overlap rejects different paths" "got: $overlap_result"
fi

# ─── Test 16: sw_discovery_ci_push no-ops when DISCOVERIES_FILE missing ───
echo ""
echo -e "  ${CYAN}ci_push subcommand (no-op when no discoveries file)${RESET}"
# Remove any discoveries file to test the no-op path
rm -f "$HOME/.shipwright/discoveries.jsonl" 2>/dev/null || true
output=$(bash "$SCRIPT_DIR/sw-discovery.sh" ci_push 2>&1) && rc=0 || rc=$?
assert_eq "ci_push exits 0 when no discoveries file" "0" "$rc"

# ─── Test 17: DISCOVERY_FILE_PATTERNS env var override ────────────────────
echo ""
echo -e "  ${CYAN}DISCOVERY_FILE_PATTERNS env var${RESET}"
# Set override and verify the variable is used when sourcing
(
    set +euo pipefail
    export DISCOVERY_FILE_PATTERNS="*.go,*.py"
    source "$SCRIPT_DIR/sw-discovery.sh" 2>/dev/null || true
    echo "PATTERN_VAR=${DISCOVERY_FILE_PATTERNS:-unset}"
) > "$TEST_TEMP_DIR/pattern_output" 2>/dev/null || true
pattern_result=$(cat "$TEST_TEMP_DIR/pattern_output" 2>/dev/null || echo "")
if echo "$pattern_result" | grep -qF "PATTERN_VAR=*.go,*.py"; then
    assert_pass "DISCOVERY_FILE_PATTERNS env var is preserved when set"
else
    assert_fail "DISCOVERY_FILE_PATTERNS env var should be preserved but was overwritten"
fi

# ─── Test 18: default DISCOVERY_FILE_PATTERNS covers broad extensions ─────
echo ""
echo -e "  ${CYAN}default DISCOVERY_FILE_PATTERNS breadth${RESET}"
# Test that pipeline-stages-build uses the broad default by checking the script text
if grep -qF "*.sh" "$SCRIPT_DIR/lib/pipeline-stages-build.sh" 2>/dev/null && \
   grep -qF "*.swift" "$SCRIPT_DIR/lib/pipeline-stages-build.sh" 2>/dev/null && \
   grep -qF "*.py" "$SCRIPT_DIR/lib/pipeline-stages-build.sh" 2>/dev/null; then
    assert_pass "default DISCOVERY_FILE_PATTERNS includes shell, swift, and python extensions"
else
    assert_fail "default DISCOVERY_FILE_PATTERNS includes shell, swift, and python extensions"
fi

echo ""
echo ""
print_test_results
