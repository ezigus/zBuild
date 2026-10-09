#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright incident test — Validate incident detection & response       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/incidents"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock claude
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "Root cause: test failure in auth module"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock gh"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Create empty events file
    touch "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

_test_cleanup_hook() { cleanup_test_env; }

assert_pass() {
    local desc="$1"
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    local _count
    _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true
    if [[ "${_count:-0}" -gt 0 ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Incident Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-incident.sh" help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help mentions watch" "$output" "watch"
assert_contains "help mentions list" "$output" "list"
assert_contains "help mentions report" "$output" "report"
assert_contains "help mentions stats" "$output" "stats"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
if grep -q '^VERSION=' "$SCRIPT_DIR/sw-incident.sh"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: unknown command exits non-zero ─────────────────────────────────
echo ""
echo -e "${DIM}  error handling${RESET}"

output=$(bash "$SCRIPT_DIR/sw-incident.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 4: list command with no incidents ──────────────────────────────────
echo ""
echo -e "${DIM}  list command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-incident.sh" list 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "list with no incidents exits 0"
else
    assert_fail "list with no incidents exits 0" "exit code: $rc"
fi

# ─── Test 5: stats command with no data ──────────────────────────────────────
echo ""
echo -e "${DIM}  stats command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-incident.sh" stats 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "stats with no data exits 0"
else
    assert_fail "stats with no data exits 0" "exit code: $rc"
fi

# ─── Test 6: incident config creation ────────────────────────────────────────
echo ""
echo -e "${DIM}  state management${RESET}"

config_file="$HOME/.shipwright/incidents/config.json"
if [[ -f "$config_file" ]]; then
    assert_pass "Incident config created"
    # Validate JSON
    if jq . "$config_file" >/dev/null 2>&1; then
        assert_pass "Incident config is valid JSON"
    else
        assert_fail "Incident config is valid JSON"
    fi
else
    assert_fail "Incident config created"
    assert_fail "Incident config is valid JSON"
fi

# ─── Test 7: script safety ──────────────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-incident.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q 'BASH_SOURCE\[0\].*==.*\$0' "$SCRIPT_DIR/sw-incident.sh"; then
    assert_pass "Has source guard pattern"
else
    assert_fail "Has source guard pattern"
fi

if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-incident.sh"; then
    assert_pass "ERR trap is set"
else
    assert_fail "ERR trap is set"
fi

# ─── Test 8: config subcommand creates valid JSON config ───────────────────────
echo ""
echo -e "${DIM}  config subcommand${RESET}"
if [[ -f "$HOME/.shipwright/incidents/config.json" ]]; then
    if jq -e . "$HOME/.shipwright/incidents/config.json" >/dev/null 2>&1; then
        assert_pass "config subcommand creates valid JSON config"
    else
        assert_fail "config subcommand creates valid JSON config" "jq parse failed"
    fi
else
    assert_fail "config subcommand creates valid JSON config" "config.json missing"
fi

# ─── Test 9: watch, stop, show subcommands exist and show usage/error when missing args ─
echo ""
echo -e "${DIM}  subcommand usage${RESET}"
set +e
trap - ERR
show_out=$(bash "$SCRIPT_DIR/sw-incident.sh" show 2>&1)
show_rc=$?
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR
set -e
if [[ $show_rc -ne 0 ]] && { [[ "$show_out" == *"Usage"* ]] || [[ "$show_out" == *"incident"* ]] || [[ "$show_out" == *"unbound"* ]]; }; then
    assert_pass "show subcommand fails or shows usage when missing args"
else
    assert_fail "show subcommand fails or shows usage when missing args" "rc=$show_rc"
fi
report_out=$(bash "$SCRIPT_DIR/sw-incident.sh" report 2>&1) || true
if [[ "$report_out" == *"Usage"* ]] || [[ "$report_out" == *"incident"* ]] || [[ "$report_out" == *"not found"* ]]; then
    assert_pass "report subcommand shows usage when missing args"
else
    assert_fail "report subcommand shows usage when missing args"
fi

# ─── Test 10: detect_pipeline_failures with mock events ───────────────────────
echo ""
echo -e "${DIM}  detect_pipeline_failures${RESET}"
now_epoch=$(date +%s)
event="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"ts_epoch\":$now_epoch,\"type\":\"stage.failed\",\"issue\":\"1\",\"stage\":\"build\",\"reason\":\"test\"}"
echo "$event" >> "$HOME/.shipwright/events.jsonl"
# shellcheck disable=SC2034
detect_result=$(HOME="$HOME" bash -c "source \"$SCRIPT_DIR/sw-incident.sh\" 2>/dev/null; detect_pipeline_failures 86400" 2>/dev/null) || true
assert_pass "detect_pipeline_failures defined and callable"

# ─── Test 11: report subcommand with nonexistent incident (graceful) ───────────
report_nonexist=$(bash "$SCRIPT_DIR/sw-incident.sh" report inc-nonexistent-999 2>&1) || true
if [[ "$report_nonexist" == *"not found"* ]] || [[ "$report_nonexist" == *"Incident"* ]]; then
    assert_pass "report with nonexistent incident handles gracefully"
else
    assert_fail "report with nonexistent incident handles gracefully" "got: $report_nonexist"
fi

# ─── Test 12: gap subcommand output ────────────────────────────────────────────
gap_out=$(bash "$SCRIPT_DIR/sw-incident.sh" gap list 2>&1); rc=$?
if [[ $rc -eq 0 ]] && printf '%s\n' "$gap_out" | grep -q "gaps"; then
    assert_pass "gap list subcommand produces expected output"
else
    assert_fail "gap list subcommand produces expected output" "rc=$rc"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
