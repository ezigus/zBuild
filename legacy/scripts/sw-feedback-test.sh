#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright feedback test — Production Feedback Loop tests               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<MOCK
#!/usr/bin/env bash
# Handle -C <dir> by shifting past it
if [[ "\${1:-}" == "-C" ]]; then shift; shift; fi
case "\${1:-}" in
    rev-parse) echo "$TEST_TEMP_DIR/repo" ;;
    log) echo "abc1234 fix: something" ;;
    show) echo "1 file changed" ;;
    config) echo "git@github.com:test/repo.git" ;;
    remote)
        case "\${2:-}" in
            get-url) echo "git@github.com:test/repo.git" ;;
            *) echo "" ;;
        esac
        ;;
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
    if command -v shasum &>/dev/null; then
        ln -sf "$(command -v shasum)" "$TEST_TEMP_DIR/bin/shasum"
    fi
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

_test_cleanup_hook() { cleanup_test_env; }

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1"; local detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; if [[ -n "$detail" ]]; then echo -e "    ${DIM}${detail}${RESET}"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cE -- "$pattern" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
print_test_header "Shipwright Feedback Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright feedback"
assert_contains "help shows subcommands" "$output" "SUBCOMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits 1" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown subcommand"

# ─── Test 4: collect with empty dir ───────────────────────────────────────
echo ""
echo -e "  ${CYAN}collect subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" collect "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts" 2>&1) && rc=0 || rc=$?
assert_eq "collect on empty dir exits 0" "0" "$rc"
assert_contains "collect shows collecting" "$output" "Collecting"

# ─── Test 5: collect reports save location ────────────────────────────────
# Note: collect saves to the git repo root, not the input dir
assert_contains "collect shows save path" "$output" "Saved to"

# ─── Test 6: collect with log file containing errors ──────────────────────
echo ""
echo -e "  ${CYAN}collect with error log${RESET}"
cat > "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/test.log" <<'LOG'
2026-01-01 Starting pipeline
Error: connection timeout
2026-01-01 Retrying...
Exception: null pointer in handler
Fatal: unrecoverable error
Normal operation resumed
LOG
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" collect "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/test.log" 2>&1) && rc=0 || rc=$?
assert_eq "collect with errors exits 0" "0" "$rc"
assert_contains "collect reports errors" "$output" "Collected"

# ─── Test 7: analyze with no error file ────────────────────────────────────
echo ""
echo -e "  ${CYAN}analyze subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" analyze "$TEST_TEMP_DIR/nonexistent.json" 2>&1) && rc=0 || rc=$?
assert_eq "analyze missing file exits 1" "1" "$rc"
assert_contains "analyze shows not found" "$output" "not found"

# ─── Test 8: analyze with collected errors ─────────────────────────────────
# Create the errors file that collect would normally produce
echo '{"total_errors": 5, "error_types": "timeout;crash;"}' > "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" analyze "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json" 2>&1) && rc=0 || rc=$?
assert_eq "analyze exits 0" "0" "$rc"
assert_contains "analyze shows report" "$output" "Error Analysis"

# ─── Test 9: learn subcommand ─────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}learn subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" learn "Off-by-one in pagination" "Fixed loop boundary" 2>&1) && rc=0 || rc=$?
assert_eq "learn exits 0" "0" "$rc"
assert_contains "learn confirms capture" "$output" "Incident captured"

# ─── Test 10: learn creates incidents file ─────────────────────────────────
if [[ -f "$HOME/.shipwright/incidents.jsonl" ]]; then
    assert_pass "incidents.jsonl created"
    line=$(head -1 "$HOME/.shipwright/incidents.jsonl")
    if echo "$line" | jq . >/dev/null 2>&1; then
        assert_pass "incidents.jsonl has valid JSONL"
    else
        assert_fail "incidents.jsonl has valid JSONL"
    fi
else
    assert_fail "incidents.jsonl created"
    assert_fail "incidents.jsonl has valid JSONL" "file missing"
fi

# ─── Test 11: report with incidents ───────────────────────────────────────
echo ""
echo -e "  ${CYAN}report subcommand${RESET}"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report exits 0" "0" "$rc"
assert_contains "report shows incidents" "$output" "Incident Report"
assert_contains "report shows total" "$output" "Total incidents"

# ─── Test 12: report with no incidents ─────────────────────────────────────
rm -f "$HOME/.shipwright/incidents.jsonl"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" report 2>&1) && rc=0 || rc=$?
assert_eq "report no incidents exits 0" "0" "$rc"
assert_contains "report says no incidents" "$output" "No incidents"

# ─── Test 13: create-issue with NO_GITHUB ──────────────────────────────────
echo ""
echo -e "  ${CYAN}create-issue subcommand${RESET}"
# First create an error file with enough errors to exceed threshold
echo '{"total_errors": 10, "error_types": "timeout;crash;"}' > "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json"
output=$(bash "$SCRIPT_DIR/sw-feedback.sh" create-issue "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts/errors-collected.json" 2>&1) && rc=0 || rc=$?
assert_eq "create-issue with NO_GITHUB exits 0" "0" "$rc"
assert_contains "create-issue skips with NO_GITHUB" "$output" "NO_GITHUB"

echo ""
echo ""
print_test_results
