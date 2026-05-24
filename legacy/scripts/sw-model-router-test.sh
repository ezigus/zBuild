#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright model-router test — Intelligent model routing & optimization ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        else echo "abc1234"; fi ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

_test_cleanup_hook() { cleanup_test_env; }

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Model Router Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: Help output ──────────────────────────────────────────────────
echo -e "${BOLD}  Help & Version${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" help 2>&1) || true
assert_contains "help shows usage" "$output" "USAGE"
assert_contains "help shows route" "$output" "route"
assert_contains "help shows escalate" "$output" "escalate"
assert_contains "help shows config" "$output" "config"

# ─── Test 2: Route model for intake (haiku stage) ────────────────────────
echo ""
echo -e "${BOLD}  Route Model${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route intake 50 2>&1)
assert_eq "route intake at 50 = haiku" "haiku" "$output"

# ─── Test 3: Route model for build (opus stage) ──────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route build 50 2>&1)
assert_eq "route build at 50 = opus" "opus" "$output"

# ─── Test 4: Route model for test (sonnet stage) ─────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route test 50 2>&1)
assert_eq "route test at 50 = sonnet" "sonnet" "$output"

# ─── Test 5: Route model with low complexity override ─────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route build 10 2>&1)
assert_eq "route build at 10 (low) = sonnet" "sonnet" "$output"

# ─── Test 6: Route model with high complexity override ────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route intake 90 2>&1)
assert_eq "route intake at 90 (high) = opus" "opus" "$output"

# ─── Test 7: Route model for unknown stage ────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" route custom_stage 50 2>&1)
assert_eq "route unknown stage at 50 = sonnet" "sonnet" "$output"

# ─── Test 8: Escalate model ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Escalate Model${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate haiku 2>&1)
assert_eq "escalate haiku -> sonnet" "sonnet" "$output"

output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate sonnet 2>&1)
assert_eq "escalate sonnet -> opus" "opus" "$output"

output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate opus 2>&1)
assert_eq "escalate opus -> opus (ceiling)" "opus" "$output"

# ─── Test 9: Escalate unknown model ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate unknown 2>&1) && rc=0 || rc=$?
assert_eq "escalate unknown exits non-zero" "1" "$rc"

# ─── Test 10: Config show creates default ─────────────────────────────────
echo ""
echo -e "${BOLD}  Config${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" config show 2>&1) || true
assert_contains "config show displays JSON" "$output" "default_routing"
# Unified config: canonical location is optimization dir
config_file="$HOME/.shipwright/optimization/model-routing.json"
if [[ -f "$config_file" ]]; then
    assert_pass "config creates default file"
else
    assert_fail "config creates default file" "file not found"
fi

# ─── Test 11: Config set ─────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" config set cost_aware_mode true 2>&1) || true
assert_contains "config set confirms update" "$output" "Updated"
value=$(jq -r '.cost_aware_mode' "$config_file")
assert_eq "config set persists value" "true" "$value"

# ─── Test 12: Estimate cost ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Estimate${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" estimate standard 50 2>&1) || true
assert_contains "estimate shows stages" "$output" "intake"
assert_contains "estimate shows total" "$output" "Total"

# ─── Test 13: Report with no data ────────────────────────────────────────
echo ""
echo -e "${BOLD}  Report${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" report 2>&1) || true
assert_contains "report with no data warns" "$output" "No usage data"

# ─── Test 14: record_usage creates usage data file ───────────────────────
echo ""
echo -e "${BOLD}  Record Usage${RESET}"
source "$SCRIPT_DIR/sw-model-router.sh" 2>/dev/null || true
record_usage "plan" "opus" 1000 500 2>/dev/null || true
record_usage "build" "sonnet" 2000 800 2>/dev/null || true
usage_file="$HOME/.shipwright/optimization/model-usage.jsonl"
if [[ -f "$usage_file" ]]; then
    assert_pass "record_usage creates usage file"
    lines=$(wc -l < "$usage_file" 2>/dev/null | tr -d ' ' || echo "0")
    assert_eq "record_usage writes entries" "2" "$lines"
else
    assert_fail "record_usage creates usage file"
fi

# ─── Test 15: Report with usage data shows summary ───────────────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" report 2>&1) || true
assert_contains "report with data shows summary" "$output" "Summary"
assert_contains "report shows total runs" "$output" "Total runs"
assert_contains "report shows cost" "$output" "cost"
assert_contains_regex "report shows model counts" "$output" "(Haiku|Sonnet|Opus) runs"

# ─── Test 16: Route for all stages at all complexity levels ──────────────
echo ""
echo -e "${BOLD}  Route All Stages & Complexity${RESET}"
for stage in intake plan design build test review compound_quality validate monitor; do
    out=$(bash "$SCRIPT_DIR/sw-model-router.sh" route "$stage" 50 2>&1)
    if [[ -n "$out" && "$out" =~ ^(haiku|sonnet|opus)$ ]]; then
        assert_pass "route $stage at 50 returns model"
    else
        assert_fail "route $stage at 50 returns model" "got: $out"
    fi
done
out_low=$(bash "$SCRIPT_DIR/sw-model-router.sh" route plan 10 2>&1)
out_high=$(bash "$SCRIPT_DIR/sw-model-router.sh" route plan 95 2>&1)
assert_eq "route plan at low complexity = sonnet" "sonnet" "$out_low"
assert_eq "route plan at high complexity = opus" "opus" "$out_high"

# ─── Test 17: Config set and config show cycle ───────────────────────────
echo ""
echo -e "${BOLD}  Config Set/Show Cycle${RESET}"
bash "$SCRIPT_DIR/sw-model-router.sh" config set cost_aware_mode false 2>/dev/null || true
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" config show 2>&1) || true
assert_contains "config show reflects settings" "$output" "cost_aware_mode"
val=$(jq -r '.cost_aware_mode' "$config_file" 2>/dev/null)
assert_eq "config set persists" "false" "$val"

# ─── Test 18: Estimate with specific stages and complexity ───────────────
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" estimate standard 25 2>&1) || true
assert_contains "estimate with low complexity shows stages" "$output" "intake"
assert_contains "estimate shows Total" "$output" "Total"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" estimate standard 75 2>&1) || true
assert_contains "estimate with high complexity" "$output" "plan"

# ─── Test 19: Unknown subcommand ────────────────────────────────────────
echo ""
echo -e "${BOLD}  Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-model-router.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown subcommand exits non-zero" "1" "$rc"
assert_contains "unknown subcommand shows error" "$output" "Unknown subcommand"

echo ""
echo ""
print_test_results
