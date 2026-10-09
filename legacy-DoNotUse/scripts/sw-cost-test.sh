#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost test — Validate token usage & cost intelligence         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
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

    # Mock sqlite3
    cat > "$TEST_TEMP_DIR/bin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo ""
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/sqlite3"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

_test_cleanup_hook() { cleanup_test_env; }

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Cost Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help shows COMMANDS" "$output" "COMMANDS"
assert_contains "help mentions show" "$output" "show"
assert_contains "help mentions budget" "$output" "budget"
assert_contains "help mentions calculate" "$output" "calculate"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
version_line=$(grep '^VERSION=' "$SCRIPT_DIR/sw-cost.sh" | head -1)
if [[ -n "$version_line" ]]; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: cost dir creation ──────────────────────────────────────────────
echo ""
echo -e "${DIM}  state management${RESET}"

# Running 'show' should create cost files
bash "$SCRIPT_DIR/sw-cost.sh" show >/dev/null 2>&1 || true
if [[ -f "$HOME/.shipwright/costs.json" ]]; then
    assert_pass "costs.json created on first use"
else
    assert_fail "costs.json created on first use"
fi
if [[ -f "$HOME/.shipwright/budget.json" ]]; then
    assert_pass "budget.json created on first use"
else
    assert_fail "budget.json created on first use"
fi

# ─── Test 4: costs.json has valid structure ─────────────────────────────────
cost_valid=$(jq -e '.entries' "$HOME/.shipwright/costs.json" >/dev/null 2>&1&& echo "yes" || echo "no")
assert_eq "costs.json has entries array" "yes" "$cost_valid"

# ─── Test 5: budget.json has valid structure ────────────────────────────────
budget_valid=$(jq -e '.daily_budget_usd' "$HOME/.shipwright/budget.json" >/dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "budget.json has daily_budget_usd" "yes" "$budget_valid"

# ─── Test 6: budget set command ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  budget commands${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" budget set 50.00 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "budget set exits 0"
else
    assert_fail "budget set exits 0" "exit code: $rc"
fi

# Verify budget was written
budget_val=$(jq -r '.daily_budget_usd' "$HOME/.shipwright/budget.json" 2>/dev/null || echo "")
assert_eq "budget set to 50" "50.00" "$budget_val"

# ─── Test 7: budget show command ────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-cost.sh" budget show 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "budget show exits 0"
else
    assert_fail "budget show exits 0" "exit code: $rc"
fi

# ─── Test 8: unknown command exits non-zero ─────────────────────────────────
echo ""
echo -e "${DIM}  error handling${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 9: calculate command ──────────────────────────────────────────────
echo ""
echo -e "${DIM}  calculate${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" calculate 50000 10000 opus 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "calculate exits 0"
else
    assert_fail "calculate exits 0" "exit code: $rc"
fi

# ─── Test 10: set -euo pipefail ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "ERR trap is set"
else
    assert_fail "ERR trap is set"
fi

# ─── Test: context efficiency section in dashboard ─────────────────────────
echo ""
echo -e "${DIM}  context efficiency in cost dashboard${RESET}"

if grep -q 'CONTEXT EFFICIENCY' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Cost dashboard has CONTEXT EFFICIENCY section"
else
    assert_fail "Cost dashboard has CONTEXT EFFICIENCY section"
fi

if grep -q 'loop.context_efficiency' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Cost dashboard reads loop.context_efficiency events"
else
    assert_fail "Cost dashboard reads loop.context_efficiency events"
fi

if grep -q 'Avg budget used' "$SCRIPT_DIR/sw-cost.sh" && grep -q 'Chars discarded' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Context efficiency reports utilization and waste"
else
    assert_fail "Context efficiency reports utilization and waste"
fi

# Functional test: write mock events and verify dashboard parses them
# Use dynamic epoch (yesterday) so the test doesn't rot as time passes
_mock_epoch=$(( $(date +%s) - 86400 ))
_mock_ts=$(date -u -r "$_mock_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
           date -u -d "@$_mock_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || \
  { echo "ERROR: date command failed on both macOS and GNU formats" >&2; exit 1; }
[[ -z "$_mock_ts" ]] && { echo "ERROR: timestamp is empty after date command" >&2; exit 1; }
mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
cat > "$TEST_TEMP_DIR/home/.shipwright/events.jsonl" <<EVTEOF
{"ts":"${_mock_ts}","type":"loop.context_efficiency","iteration":"1","raw_prompt_chars":"200000","trimmed_prompt_chars":"180000","trim_ratio":"10.0","budget_utilization":"100.0","budget_chars":"180000","job_id":"test-1"}
{"ts":"${_mock_ts}","type":"loop.context_efficiency","iteration":"2","raw_prompt_chars":"150000","trimmed_prompt_chars":"150000","trim_ratio":"0.0","budget_utilization":"83.3","budget_chars":"180000","job_id":"test-1"}
EVTEOF

# Also need cost data for the dashboard to run
cat > "$TEST_TEMP_DIR/home/.shipwright/costs.json" <<COSTEOF
{"entries":[{"ts":"${_mock_ts}","ts_epoch":${_mock_epoch},"input_tokens":50000,"output_tokens":10000,"cost_usd":1.50,"model":"opus","stage":"build","issue":"1"}],"summary":{}}
COSTEOF
cat > "$TEST_TEMP_DIR/home/.shipwright/budget.json" <<'BUDEOF'
{"daily_budget_usd":0,"enabled":false}
BUDEOF

dash_output=$(env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" show --period 30 2>&1) || true

if echo "$dash_output" | grep -q "CONTEXT EFFICIENCY"; then
    assert_pass "Dashboard renders CONTEXT EFFICIENCY with event data"
else
    assert_fail "Dashboard renders CONTEXT EFFICIENCY with event data" "output: $(echo "$dash_output" | tail -5)"
fi

if echo "$dash_output" | grep -q "Avg budget used"; then
    assert_pass "Dashboard shows avg budget utilization"
else
    assert_fail "Dashboard shows avg budget utilization"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: per-iteration and stage-level cost attribution (issue #87)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Per-Iteration and Stage-Level Cost Attribution${RESET}"

# ── Test 1: cost_generate_breakdown with sidecar data ──────────────────────────
_bd_dir="$TEST_TEMP_DIR/breakdown-test"
mkdir -p "$_bd_dir"
_now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '%s\n' \
    "{\"iteration\":1,\"input_tokens\":5000,\"output_tokens\":2000,\"cost_usd\":0.045,\"ts\":\"${_now}\"}" \
    "{\"iteration\":2,\"input_tokens\":4000,\"output_tokens\":1800,\"cost_usd\":0.039,\"ts\":\"${_now}\"}" \
    "{\"iteration\":3,\"input_tokens\":3500,\"output_tokens\":1500,\"cost_usd\":0.033,\"ts\":\"${_now}\"}" \
    > "$_bd_dir/loop-iteration-costs.jsonl"
printf '%s\n' \
    "{\"stage\":\"build\",\"input_tokens\":12500,\"output_tokens\":5300,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    "{\"stage\":\"review\",\"input_tokens\":3000,\"output_tokens\":1000,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    > "$_bd_dir/stage-costs.jsonl"

_bd_out=$(env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" breakdown "$_bd_dir" "test-pipeline" "87" 2>&1) || true

if [[ -f "$_bd_dir/cost-breakdown.json" ]]; then
    assert_pass "cost_generate_breakdown creates cost-breakdown.json"
    _iter_count=$(jq '.summary.iteration_count' "$_bd_dir/cost-breakdown.json" 2>/dev/null || echo "")
    _stage_count=$(jq '.by_stage | length' "$_bd_dir/cost-breakdown.json" 2>/dev/null || echo "")
    _iter_len=$(jq '.by_iteration | length' "$_bd_dir/cost-breakdown.json" 2>/dev/null || echo "")
    if [[ "$_iter_count" == "3" ]]; then
        assert_pass "breakdown: summary.iteration_count == 3"
    else
        assert_fail "breakdown: summary.iteration_count == 3" "got: ${_iter_count}"
    fi
    if [[ "$_stage_count" == "2" ]]; then
        assert_pass "breakdown: by_stage has 2 entries"
    else
        assert_fail "breakdown: by_stage has 2 entries" "got: ${_stage_count}"
    fi
    if [[ "$_iter_len" == "3" ]]; then
        assert_pass "breakdown: by_iteration has 3 entries"
    else
        assert_fail "breakdown: by_iteration has 3 entries" "got: ${_iter_len}"
    fi
else
    assert_fail "cost_generate_breakdown creates cost-breakdown.json" "output: $(echo "$_bd_out" | tail -3)"
    assert_fail "breakdown: summary.iteration_count == 3"
    assert_fail "breakdown: by_stage has 2 entries"
    assert_fail "breakdown: by_iteration has 3 entries"
fi

# ── Test 2: cost_generate_breakdown with no sidecars ───────────────────────────
_bd_empty="$TEST_TEMP_DIR/breakdown-empty"
mkdir -p "$_bd_empty"
env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" breakdown "$_bd_empty" "empty-pipeline" "" 2>&1 || true

if [[ -f "$_bd_empty/cost-breakdown.json" ]]; then
    _empty_iter=$(jq '.by_iteration | length' "$_bd_empty/cost-breakdown.json" 2>/dev/null || echo "err")
    _empty_stage=$(jq '.by_stage | length' "$_bd_empty/cost-breakdown.json" 2>/dev/null || echo "err")
    if [[ "$_empty_iter" == "0" && "$_empty_stage" == "0" ]]; then
        assert_pass "breakdown with no sidecars produces valid JSON with empty arrays"
    else
        assert_fail "breakdown with no sidecars produces valid JSON with empty arrays" \
            "by_iteration=${_empty_iter} by_stage=${_empty_stage}"
    fi
else
    assert_fail "breakdown with no sidecars produces valid JSON with empty arrays"
fi

# ── Test 3: --by-iteration flag ─────────────────────────────────────────────────
_bd_flag_dir="$TEST_TEMP_DIR/breakdown-flag"
mkdir -p "$_bd_flag_dir"
printf '%s\n' \
    "{\"pipeline_id\":\"p1\",\"issue\":\"87\",\"generated_at\":\"${_now}\",\"summary\":{\"total_input_tokens\":12500,\"total_output_tokens\":5300,\"iteration_count\":2,\"stage_count\":1},\"by_stage\":[{\"stage\":\"build\",\"input_tokens\":12500,\"output_tokens\":5300}],\"by_iteration\":[{\"iteration\":1,\"input_tokens\":5000,\"output_tokens\":2000,\"cost_usd\":0.045,\"ts\":\"${_now}\"},{\"iteration\":2,\"input_tokens\":4000,\"output_tokens\":1800,\"cost_usd\":0.039,\"ts\":\"${_now}\"}]}" \
    > "$_bd_flag_dir/cost-breakdown.json"

_iter_output=$(env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    ARTIFACTS_DIR="$_bd_flag_dir" \
    bash "$SCRIPT_DIR/sw-cost.sh" show --by-iteration 2>&1) || true
if echo "$_iter_output" | grep -qi "by iteration\|BY ITERATION"; then
    assert_pass "--by-iteration flag renders iteration section"
else
    assert_fail "--by-iteration flag renders iteration section" "output: $(echo "$_iter_output" | grep -i iter | head -3)"
fi

_no_iter_dir="$TEST_TEMP_DIR/no-iter-artifacts"
mkdir -p "$_no_iter_dir"
_no_iter_output=$(env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    ARTIFACTS_DIR="$_no_iter_dir" \
    bash "$SCRIPT_DIR/sw-cost.sh" show --by-iteration 2>&1) || true
if echo "$_no_iter_output" | grep -qi "no iteration data\|no.*iteration\|iteration.*data"; then
    assert_pass "--by-iteration with no artifact shows graceful message"
else
    assert_fail "--by-iteration with no artifact shows graceful message" "output: $(echo "$_no_iter_output" | tail -3)"
fi

# ── Test 4: record_iteration_cost from lib/loop-cost.sh ───────────────────────
_loop_cost_lib="$SCRIPT_DIR/lib/cost/iteration.sh"
if [[ -f "$_loop_cost_lib" ]]; then
    _iter_sidecar="$TEST_TEMP_DIR/test-iter-costs.jsonl"
    (
        # Source the lib in a subshell to avoid polluting test environment
        ITER_COST_JSONL="$_iter_sidecar"
        LOOP_INPUT_TOKENS=0
        LOOP_OUTPUT_TOKENS=0
        LOOP_COST_MILLICENTS=0
        # shellcheck source=/dev/null
        source "$_loop_cost_lib"
        # Iteration 1
        _ITER_SNAP_INPUT=0; _ITER_SNAP_OUTPUT=0; _ITER_SNAP_COST_MC=0
        LOOP_INPUT_TOKENS=5000; LOOP_OUTPUT_TOKENS=2000; LOOP_COST_MILLICENTS=450
        record_iteration_cost 1
        # Iteration 2
        _ITER_SNAP_INPUT=5000; _ITER_SNAP_OUTPUT=2000; _ITER_SNAP_COST_MC=450
        LOOP_INPUT_TOKENS=9000; LOOP_OUTPUT_TOKENS=3800; LOOP_COST_MILLICENTS=840
        record_iteration_cost 2
        # Iteration 3
        _ITER_SNAP_INPUT=9000; _ITER_SNAP_OUTPUT=3800; _ITER_SNAP_COST_MC=840
        LOOP_INPUT_TOKENS=12500; LOOP_OUTPUT_TOKENS=5300; LOOP_COST_MILLICENTS=1170
        record_iteration_cost 3
    )
    _line_count=$(wc -l < "$_iter_sidecar" 2>/dev/null | tr -d ' ' || echo "0")
    _iter3_num=$(jq -r 'select(.iteration==3) | .iteration' "$_iter_sidecar" 2>/dev/null | head -1 || echo "")
    _iter1_input=$(jq -r 'select(.iteration==1) | .input_tokens' "$_iter_sidecar" 2>/dev/null | head -1 || echo "")
    if [[ "$_line_count" == "3" ]]; then
        assert_pass "record_iteration_cost: sidecar has 3 lines"
    else
        assert_fail "record_iteration_cost: sidecar has 3 lines" "got: ${_line_count}"
    fi
    if [[ "$_iter3_num" == "3" ]]; then
        assert_pass "record_iteration_cost: iteration numbers are 1/2/3"
    else
        assert_fail "record_iteration_cost: iteration numbers are 1/2/3" "got iter3: ${_iter3_num}"
    fi
    if [[ "$_iter1_input" == "5000" ]]; then
        assert_pass "record_iteration_cost: iteration 1 delta input_tokens correct (5000)"
    else
        assert_fail "record_iteration_cost: iteration 1 delta input_tokens correct (5000)" "got: ${_iter1_input}"
    fi
else
    assert_fail "record_iteration_cost: lib/cost/iteration.sh exists" "file not found: $_loop_cost_lib"
    assert_fail "record_iteration_cost: sidecar has 3 lines"
    assert_fail "record_iteration_cost: iteration numbers are 1/2/3"
    assert_fail "record_iteration_cost: iteration 1 delta input_tokens correct (5000)"
fi

# ── Test 5: record_stage_cost_start/end from lib/stage-cost.sh ─────────────────
_stage_cost_lib="$SCRIPT_DIR/lib/cost/stage.sh"
if [[ -f "$_stage_cost_lib" ]]; then
    _stage_sidecar_dir="$TEST_TEMP_DIR/stage-cost-test"
    mkdir -p "$_stage_sidecar_dir"
    (
        ARTIFACTS_DIR="$_stage_sidecar_dir"
        TOTAL_INPUT_TOKENS=0
        TOTAL_OUTPUT_TOKENS=0
        MODEL="sonnet"
        ISSUE_NUMBER="87"
        # Stub cost_record as noop so the lib works without sw-cost.sh loaded
        cost_record() { return 0; }
        emit_event() { return 0; }
        # shellcheck source=/dev/null
        source "$_stage_cost_lib"
        record_stage_cost_start "plan"
        TOTAL_INPUT_TOKENS=8000
        TOTAL_OUTPUT_TOKENS=3000
        record_stage_cost_end "plan"
    )
    if [[ -f "$_stage_sidecar_dir/stage-costs.jsonl" ]]; then
        _sc_stage=$(jq -r '.stage' "$_stage_sidecar_dir/stage-costs.jsonl" 2>/dev/null | head -1)
        _sc_input=$(jq -r '.input_tokens' "$_stage_sidecar_dir/stage-costs.jsonl" 2>/dev/null | head -1)
        _sc_ts_epoch=$(jq -r '.ts_epoch // empty' "$_stage_sidecar_dir/stage-costs.jsonl" 2>/dev/null | head -1)
        _sc_issue=$(jq -r '.issue // empty' "$_stage_sidecar_dir/stage-costs.jsonl" 2>/dev/null | head -1)
        if [[ "$_sc_stage" == "plan" ]]; then
            assert_pass "record_stage_cost_end: stage-costs.jsonl has stage=plan"
        else
            assert_fail "record_stage_cost_end: stage-costs.jsonl has stage=plan" "got: ${_sc_stage}"
        fi
        if [[ "$_sc_input" == "8000" ]]; then
            assert_pass "record_stage_cost_end: input_tokens delta correct (8000)"
        else
            assert_fail "record_stage_cost_end: input_tokens delta correct (8000)" "got: ${_sc_input}"
        fi
        if [[ -n "$_sc_ts_epoch" ]] && [[ "$_sc_ts_epoch" =~ ^[0-9]+$ ]]; then
            assert_pass "record_stage_cost_end: ts_epoch field present and numeric (schema parity)"
        else
            assert_fail "record_stage_cost_end: ts_epoch field present and numeric" "got: '${_sc_ts_epoch}'"
        fi
        if [[ "$_sc_issue" == "87" ]]; then
            assert_pass "record_stage_cost_end: issue field propagated from ISSUE_NUMBER"
        else
            assert_fail "record_stage_cost_end: issue field propagated from ISSUE_NUMBER" "got: '${_sc_issue}'"
        fi
    else
        assert_fail "record_stage_cost_end: stage-costs.jsonl has stage=plan" "file not created"
        assert_fail "record_stage_cost_end: input_tokens delta correct (8000)"
        assert_fail "record_stage_cost_end: ts_epoch field present and numeric"
        assert_fail "record_stage_cost_end: issue field propagated from ISSUE_NUMBER"
    fi
else
    assert_fail "record_stage_cost_end: lib/cost/stage.sh exists" "file not found: $_stage_cost_lib"
    assert_fail "record_stage_cost_end: stage-costs.jsonl has stage=plan"
    assert_fail "record_stage_cost_end: input_tokens delta correct (8000)"
    assert_fail "record_stage_cost_end: ts_epoch field present and numeric"
    assert_fail "record_stage_cost_end: issue field propagated from ISSUE_NUMBER"
fi

# ── Test 6: AC#1 regression — 4 distinct stages in by_stage ──────────────────
_bd_ac1="$TEST_TEMP_DIR/breakdown-ac1"
mkdir -p "$_bd_ac1"
printf '%s\n' \
    "{\"stage\":\"plan\",\"input_tokens\":8000,\"output_tokens\":3000,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    "{\"stage\":\"design\",\"input_tokens\":6000,\"output_tokens\":2500,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    "{\"stage\":\"build\",\"input_tokens\":12500,\"output_tokens\":5300,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    "{\"stage\":\"review\",\"input_tokens\":3000,\"output_tokens\":1000,\"model\":\"sonnet\",\"ts\":\"${_now}\"}" \
    > "$_bd_ac1/stage-costs.jsonl"

env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" breakdown "$_bd_ac1" "ac1-test" "87" 2>&1 || true

if [[ -f "$_bd_ac1/cost-breakdown.json" ]]; then
    _ac1_stages=$(jq '[.by_stage[].stage] | sort | unique | length' "$_bd_ac1/cost-breakdown.json" 2>/dev/null || echo "0")
    _ac1_all_nonzero=$(jq '[.by_stage[] | select(.input_tokens > 0)] | length' "$_bd_ac1/cost-breakdown.json" 2>/dev/null || echo "0")
    if [[ "$_ac1_stages" == "4" ]]; then
        assert_pass "AC#1 regression: by_stage has 4 distinct stage names (not just 'pipeline')"
    else
        assert_fail "AC#1 regression: by_stage has 4 distinct stage names" "got: ${_ac1_stages}"
    fi
    if [[ "$_ac1_all_nonzero" == "4" ]]; then
        assert_pass "AC#1 regression: all 4 stages have non-zero input_tokens"
    else
        assert_fail "AC#1 regression: all 4 stages have non-zero input_tokens" "got: ${_ac1_all_nonzero}"
    fi
else
    assert_fail "AC#1 regression: by_stage has 4 distinct stage names"
    assert_fail "AC#1 regression: all 4 stages have non-zero input_tokens"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: pipeline integration wiring (issue #87)
# Grep-based — confirm libs are sourced, brackets are inserted, sidecars are wired.
# Cheap and fast; does not run the pipeline end-to-end.
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Pipeline Integration Wiring${RESET}"

_pipeline_sh="$SCRIPT_DIR/sw-pipeline.sh"
_loop_sh="$SCRIPT_DIR/sw-loop.sh"
_build_sh="$SCRIPT_DIR/lib/pipeline-stages-build.sh"

if grep -q 'lib/cost/stage.sh' "$_pipeline_sh"; then
    assert_pass "sw-pipeline.sh sources lib/cost/stage.sh"
else
    assert_fail "sw-pipeline.sh sources lib/cost/stage.sh"
fi

if grep -q 'record_stage_cost_start "\$stage_id"' "$_pipeline_sh" && \
   grep -q 'record_stage_cost_end "\$stage_id"' "$_pipeline_sh"; then
    assert_pass "run_stage_with_retry brackets every stage with start/end"
else
    assert_fail "run_stage_with_retry brackets every stage with start/end"
fi

if grep -q 'cost_generate_breakdown "\$ARTIFACTS_DIR"' "$_pipeline_sh"; then
    assert_pass "sw-pipeline.sh invokes cost_generate_breakdown from cleanup_on_exit"
else
    assert_fail "sw-pipeline.sh invokes cost_generate_breakdown from cleanup_on_exit"
fi

if grep -q 'lib/cost/iteration.sh' "$_loop_sh"; then
    assert_pass "sw-loop.sh sources lib/cost/iteration.sh"
else
    assert_fail "sw-loop.sh sources lib/cost/iteration.sh"
fi

if grep -q '_ITER_SNAP_INPUT=' "$_loop_sh" && \
   grep -q 'record_iteration_cost "\$ITERATION"' "$_loop_sh"; then
    assert_pass "sw-loop.sh snapshots and records each iteration's cost"
else
    assert_fail "sw-loop.sh snapshots and records each iteration's cost"
fi

if grep -q 'export ITER_COST_JSONL=' "$_build_sh"; then
    assert_pass "stage_build exports ITER_COST_JSONL to sw loop subprocess"
else
    assert_fail "stage_build exports ITER_COST_JSONL to sw loop subprocess"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: end-to-end bracket pattern (issue #87 functional verification)
# Simulates run_stage_with_retry's bracketing using real lib functions and asserts
# the produced cost-breakdown.json has per-stage cost_usd and a coherent summary.
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}End-to-End Bracket Pattern${RESET}"

_e2e_dir="$TEST_TEMP_DIR/e2e-bracket"
mkdir -p "$_e2e_dir"
(
    set +u  # libs may reference unset vars under strict mode in subshell setup
    ARTIFACTS_DIR="$_e2e_dir"
    TOTAL_INPUT_TOKENS=0
    TOTAL_OUTPUT_TOKENS=0
    MODEL="sonnet"
    ISSUE_NUMBER="87"
    SHIPWRIGHT_PIPELINE_ID="e2e-test-pipeline"
    cost_record() { return 0; }
    emit_event() { return 0; }
    # Real cost_calculate from sw-cost.sh would normally be sourced; provide a
    # cheap stand-in so the sidecar gets a non-zero cost_usd field.
    cost_calculate() {
        # sonnet rates: $3/M input, $15/M output → simple linear
        awk -v it="$1" -v ot="$2" 'BEGIN { printf "%.6f", (it/1000000)*3 + (ot/1000000)*15 }'
    }
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/cost/stage.sh"

    # Simulate plan stage: 8000 in, 3000 out
    record_stage_cost_start "plan"
    TOTAL_INPUT_TOKENS=$((TOTAL_INPUT_TOKENS + 8000))
    TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + 3000))
    record_stage_cost_end "plan"

    # Simulate design stage: 6000 in, 2500 out
    record_stage_cost_start "design"
    TOTAL_INPUT_TOKENS=$((TOTAL_INPUT_TOKENS + 6000))
    TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + 2500))
    record_stage_cost_end "design"

    # Simulate build stage with retry: first attempt 5000/2000, retry 7500/3300
    record_stage_cost_start "build"
    TOTAL_INPUT_TOKENS=$((TOTAL_INPUT_TOKENS + 5000))
    TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + 2000))
    record_stage_cost_end "build"  # first attempt failed
    record_stage_cost_start "build"
    TOTAL_INPUT_TOKENS=$((TOTAL_INPUT_TOKENS + 7500))
    TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + 3300))
    record_stage_cost_end "build"  # second attempt succeeded
)

# Also seed iteration sidecar so breakdown is comprehensive
printf '%s\n' \
    "{\"iteration\":1,\"input_tokens\":3000,\"output_tokens\":1200,\"cost_usd\":0.027,\"ts\":\"${_now}\"}" \
    "{\"iteration\":2,\"input_tokens\":4500,\"output_tokens\":2100,\"cost_usd\":0.0455,\"ts\":\"${_now}\"}" \
    > "$_e2e_dir/loop-iteration-costs.jsonl"

env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" breakdown "$_e2e_dir" "e2e-test-pipeline" "87" >/dev/null 2>&1 || true

if [[ -f "$_e2e_dir/cost-breakdown.json" ]]; then
    # Three logical stages: plan, design, build. Build has 2 records (retry).
    _e2e_stages=$(jq '[.by_stage[].stage] | sort | unique | length' "$_e2e_dir/cost-breakdown.json")
    if [[ "$_e2e_stages" == "3" ]]; then
        assert_pass "e2e: 3 distinct stages (plan, design, build) recorded"
    else
        assert_fail "e2e: 3 distinct stages recorded" "got: ${_e2e_stages}"
    fi

    # Build's combined input should be 5000 + 7500 = 12500
    _e2e_build_in=$(jq -r '.by_stage[] | select(.stage=="build") | .input_tokens' "$_e2e_dir/cost-breakdown.json")
    if [[ "$_e2e_build_in" == "12500" ]]; then
        assert_pass "e2e: build stage aggregates retry deltas (5000+7500=12500)"
    else
        assert_fail "e2e: build stage aggregates retry deltas" "got: ${_e2e_build_in}"
    fi

    # Each stage must have non-zero cost_usd (AC#1: tokens AND cost)
    _e2e_cost_count=$(jq '[.by_stage[] | select(.cost_usd > 0)] | length' "$_e2e_dir/cost-breakdown.json")
    if [[ "$_e2e_cost_count" == "3" ]]; then
        assert_pass "e2e: every stage has non-zero cost_usd (AC#1)"
    else
        assert_fail "e2e: every stage has non-zero cost_usd" "got: ${_e2e_cost_count}"
    fi

    # Summary total_cost_usd must include both stage and iteration costs
    _e2e_total_cost=$(jq -r '.summary.total_cost_usd // 0' "$_e2e_dir/cost-breakdown.json")
    if awk -v t="$_e2e_total_cost" 'BEGIN { exit !(t > 0) }' 2>/dev/null; then
        assert_pass "e2e: summary.total_cost_usd > 0"
    else
        assert_fail "e2e: summary.total_cost_usd > 0" "got: ${_e2e_total_cost}"
    fi

    # Summary uses stage data as authoritative (iterations are sub-breakdown of build,
    # so summing both would double-count the build stage).
    _e2e_total_in=$(jq -r '.summary.total_input_tokens // 0' "$_e2e_dir/cost-breakdown.json")
    # Stages: 8000 + 6000 + 12500 = 26500.
    if [[ "$_e2e_total_in" == "26500" ]]; then
        assert_pass "e2e: summary.total_input_tokens = stage total (no double-count)"
    else
        assert_fail "e2e: summary.total_input_tokens = stage total" "got: ${_e2e_total_in}"
    fi

    # Breakdown stages must carry a models[] array (model attribution preserved after group_by)
    _e2e_models_count=$(jq '[.by_stage[] | select((.models | type) == "array")] | length' "$_e2e_dir/cost-breakdown.json" 2>/dev/null || echo "0")
    if [[ "$_e2e_models_count" == "3" ]]; then
        assert_pass "e2e: every stage has models[] array (model attribution preserved)"
    else
        assert_fail "e2e: every stage has models[] array" "got: ${_e2e_models_count} stages with models"
    fi
else
    assert_fail "e2e: cost-breakdown.json produced"
    assert_fail "e2e: 3 distinct stages recorded"
    assert_fail "e2e: build stage aggregates retry deltas"
    assert_fail "e2e: every stage has non-zero cost_usd"
    assert_fail "e2e: summary.total_cost_usd > 0"
    assert_fail "e2e: summary.total_input_tokens unions stages + iterations"
    assert_fail "e2e: every stage has models[] array"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: malformed-line resilience (jq filters drop bad records gracefully)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Resilience to Malformed Sidecar Lines${RESET}"

_resil_dir="$TEST_TEMP_DIR/resil"
mkdir -p "$_resil_dir"
{
    echo '{"stage":"plan","input_tokens":1000,"output_tokens":500,"cost_usd":0.001,"model":"sonnet","ts":"'"${_now}"'"}'
    echo 'this is not valid json'
    echo '{"input_tokens":999}'  # missing .stage — should be filtered
    echo '{"stage":"build","input_tokens":2000,"output_tokens":800,"cost_usd":0.005,"model":"sonnet","ts":"'"${_now}"'"}'
} > "$_resil_dir/stage-costs.jsonl"

{
    echo '{"iteration":1,"input_tokens":500,"output_tokens":200,"cost_usd":0.001,"ts":"'"${_now}"'"}'
    echo '{"iteration":"bad","input_tokens":99}'  # iteration not numeric — should be filtered
    echo '{"iteration":2,"input_tokens":700,"output_tokens":300,"cost_usd":0.0015,"ts":"'"${_now}"'"}'
} > "$_resil_dir/loop-iteration-costs.jsonl"

env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" breakdown "$_resil_dir" "resil-test" "" >/dev/null 2>&1 || true

if [[ -f "$_resil_dir/cost-breakdown.json" ]]; then
    _resil_stages=$(jq '.by_stage | length' "$_resil_dir/cost-breakdown.json")
    _resil_iters=$(jq '.by_iteration | length' "$_resil_dir/cost-breakdown.json")
    if [[ "$_resil_stages" == "2" ]]; then
        assert_pass "malformed stage lines filtered (kept 2 of 4)"
    else
        assert_fail "malformed stage lines filtered (kept 2 of 4)" "got: ${_resil_stages}"
    fi
    if [[ "$_resil_iters" == "2" ]]; then
        assert_pass "non-numeric iteration filtered (kept 2 of 3)"
    else
        assert_fail "non-numeric iteration filtered (kept 2 of 3)" "got: ${_resil_iters}"
    fi
else
    assert_fail "malformed stage lines filtered (kept 2 of 4)"
    assert_fail "non-numeric iteration filtered (kept 2 of 3)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: --by-iteration auto-generates breakdown from sidecars
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}--by-iteration Auto-Regeneration${RESET}"

_auto_dir="$TEST_TEMP_DIR/auto-regen"
mkdir -p "$_auto_dir"
# Sidecars present, but cost-breakdown.json absent — show should regenerate it.
printf '%s\n' \
    "{\"iteration\":1,\"input_tokens\":1500,\"output_tokens\":600,\"cost_usd\":0.0135,\"ts\":\"${_now}\"}" \
    > "$_auto_dir/loop-iteration-costs.jsonl"

# Need cost data so the dashboard runs
cat > "$TEST_TEMP_DIR/home/.shipwright/costs.json" <<COSTEOF
{"entries":[{"ts":"${_mock_ts}","ts_epoch":${_mock_epoch},"input_tokens":1000,"output_tokens":500,"cost_usd":0.01,"model":"sonnet","stage":"build","issue":"87"}],"summary":{}}
COSTEOF

_auto_out=$(env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    ARTIFACTS_DIR="$_auto_dir" \
    bash "$SCRIPT_DIR/sw-cost.sh" show --by-iteration --period 30 2>&1) || true

if [[ -f "$_auto_dir/cost-breakdown.json" ]]; then
    assert_pass "--by-iteration auto-regenerates cost-breakdown.json from sidecars"
else
    assert_fail "--by-iteration auto-regenerates cost-breakdown.json from sidecars" \
        "no cost-breakdown.json in $_auto_dir"
fi

if echo "$_auto_out" | grep -qE 'iter +1 +'; then
    assert_pass "--by-iteration prints iteration row after auto-regen"
else
    assert_fail "--by-iteration prints iteration row after auto-regen" \
        "output tail: $(echo "$_auto_out" | tail -5)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: per-stage cost summary table + rolling baselines (#504 deliverable 2)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Per-Stage Cost Summary Table & Rolling Baselines (#504)${RESET}"

# Helper — run sw-cost.sh in test sandbox with isolated baseline dir.
_sw_cost_isolated() {
    local _baseline_dir="${1:?need baseline dir}"; shift
    env HOME="$TEST_TEMP_DIR/home" \
        PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
        SW_BASELINE_DIR="$_baseline_dir" \
        bash "$SCRIPT_DIR/sw-cost.sh" "$@"
}

# ── Test: render with no breakdown file is graceful ─────────────────────────
_bl_dir1="$TEST_TEMP_DIR/baselines-1"
_art1="$TEST_TEMP_DIR/render-empty"
mkdir -p "$_art1"
_render_empty=$(_sw_cost_isolated "$_bl_dir1" breakdown "$_art1" "p-empty" "" --render --print-only 2>&1) || true
if echo "$_render_empty" | grep -qi "no cost-breakdown.json\|missing"; then
    assert_pass "render: missing breakdown file is graceful (warns, exits non-zero)"
else
    assert_fail "render: missing breakdown file is graceful" "output: $(echo "$_render_empty" | tail -3)"
fi

# ── Test: full render flow with synthetic single-stage data, first run = NEW ──
_bl_dir2="$TEST_TEMP_DIR/baselines-2"
_art2="$TEST_TEMP_DIR/render-first"
mkdir -p "$_art2"
_now2=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '%s\n' \
    "{\"stage\":\"intake\",\"input_tokens\":12450,\"output_tokens\":1230,\"cost_usd\":0.0042,\"model\":\"sonnet\",\"ts\":\"${_now2}\",\"ts_epoch\":1746320400,\"issue\":\"504\"}" \
    "{\"stage\":\"build\",\"input_tokens\":312000,\"output_tokens\":28400,\"cost_usd\":0.92,\"model\":\"opus\",\"ts\":\"${_now2}\",\"ts_epoch\":1746320460,\"issue\":\"504\"}" \
    > "$_art2/stage-costs.jsonl"

_render_first=$(_sw_cost_isolated "$_bl_dir2" breakdown "$_art2" "p1" "504" --render 2>&1) || true

if echo "$_render_first" | grep -q '┌'; then
    assert_pass "render: prints box-drawing table border"
else
    assert_fail "render: prints box-drawing table border" "output: $(echo "$_render_first" | head -8)"
fi
if echo "$_render_first" | grep -q "intake" && echo "$_render_first" | grep -q "build"; then
    assert_pass "render: includes both stage rows"
else
    assert_fail "render: includes both stage rows" "output: $(echo "$_render_first" | head -10)"
fi
if echo "$_render_first" | grep -q "TOTAL"; then
    assert_pass "render: includes TOTAL row"
else
    assert_fail "render: includes TOTAL row"
fi
if echo "$_render_first" | grep -q "new"; then
    assert_pass "render: first run flags stages as 'new' (no baseline yet)"
else
    assert_fail "render: first run flags stages as 'new'" "output: $(echo "$_render_first" | head -10)"
fi
# Baseline file created
if [[ -f "$_bl_dir2/stage-costs.json" && -f "$_bl_dir2/issue-504-costs.json" ]]; then
    assert_pass "render: creates both all-issues and per-issue baseline files"
else
    assert_fail "render: creates both baseline files" "ls: $(ls -la "$_bl_dir2" 2>&1)"
fi

# ── Test: baseline n=1 after first run, avg matches input cost ──────────────
_n1=$(jq '.stages.build.n' "$_bl_dir2/stage-costs.json" 2>/dev/null || echo "")
_avg1=$(jq '.stages.build.avg_usd' "$_bl_dir2/stage-costs.json" 2>/dev/null || echo "")
if [[ "$_n1" == "1" && "$_avg1" == "0.92" ]]; then
    assert_pass "baseline: n=1 and avg_usd=0.92 after first run"
else
    assert_fail "baseline: n=1 and avg_usd=0.92" "n=${_n1} avg=${_avg1}"
fi

# ── Test: rolling avg across 3 runs ─────────────────────────────────────────
_bl_dir3="$TEST_TEMP_DIR/baselines-3"
for _i in 1 2 3; do
    _r="$TEST_TEMP_DIR/roll-${_i}"; mkdir -p "$_r"
    # Costs 0.10, 0.20, 0.30 → avg should be 0.20
    printf '{"stage":"plan","input_tokens":1000,"output_tokens":100,"cost_usd":0.%d00,"model":"sonnet","ts":"%s","ts_epoch":1,"issue":""}\n' \
        "$_i" "$_now2" > "$_r/stage-costs.jsonl"
    _sw_cost_isolated "$_bl_dir3" breakdown "$_r" "p${_i}" "" --render >/dev/null 2>&1 || true
done
_n3=$(jq '.stages.plan.n' "$_bl_dir3/stage-costs.json" 2>/dev/null || echo "")
_avg3=$(jq '.stages.plan.avg_usd' "$_bl_dir3/stage-costs.json" 2>/dev/null || echo "")
if [[ "$_n3" == "3" ]] && awk -v a="$_avg3" 'BEGIN {exit !(a >= 0.19 && a <= 0.21)}'; then
    assert_pass "baseline: rolling avg across 3 runs (0.10, 0.20, 0.30) ≈ 0.20"
else
    assert_fail "baseline: rolling avg across 3 runs ≈ 0.20" "n=${_n3} avg=${_avg3}"
fi

# ── Test: HIGH/LOW classification after baseline established (n>=3) ─────────
# Reuse baselines-3 above. Plan baseline avg=0.20 (n=3). Now feed 4th run:
#   - plan at 0.50 → 2.5× → HIGH
#   - plan at 0.05 → 0.25× → LOW
_r_hi="$TEST_TEMP_DIR/roll-high"; mkdir -p "$_r_hi"
printf '{"stage":"plan","input_tokens":1000,"output_tokens":100,"cost_usd":0.500,"model":"sonnet","ts":"%s","ts_epoch":1,"issue":""}\n' \
    "$_now2" > "$_r_hi/stage-costs.jsonl"
_render_high=$(_sw_cost_isolated "$_bl_dir3" breakdown "$_r_hi" "p-hi" "" --render --no-update-baseline 2>&1) || true
# Match only the plan data row (avoid legend footer false-positive)
if echo "$_render_high" | grep -E '│ plan ' | grep -qE 'HIGH|↑'; then
    assert_pass "classify: cost 2.5× of avg flagged HIGH"
else
    assert_fail "classify: cost 2.5× of avg flagged HIGH" \
        "row: $(echo "$_render_high" | grep -E '│ plan ')"
fi

_r_lo="$TEST_TEMP_DIR/roll-low"; mkdir -p "$_r_lo"
printf '{"stage":"plan","input_tokens":1000,"output_tokens":100,"cost_usd":0.050,"model":"sonnet","ts":"%s","ts_epoch":1,"issue":""}\n' \
    "$_now2" > "$_r_lo/stage-costs.jsonl"
_render_low=$(_sw_cost_isolated "$_bl_dir3" breakdown "$_r_lo" "p-lo" "" --render --no-update-baseline 2>&1) || true
# Match only the plan data row (avoid legend footer false-positive)
if echo "$_render_low" | grep -E '│ plan ' | grep -qE 'low|↓'; then
    assert_pass "classify: cost 0.25× of avg flagged LOW"
else
    assert_fail "classify: cost 0.25× of avg flagged LOW" \
        "row: $(echo "$_render_low" | grep -E '│ plan ')"
fi

# ── Test: bootstrap guard — n<3 returns NORMAL (no false alarms) ───────────
_bl_dir4="$TEST_TEMP_DIR/baselines-4"
_r_first="$TEST_TEMP_DIR/boot-1"; mkdir -p "$_r_first"
printf '{"stage":"plan","input_tokens":1000,"output_tokens":100,"cost_usd":0.10,"model":"sonnet","ts":"%s","ts_epoch":1,"issue":""}\n' \
    "$_now2" > "$_r_first/stage-costs.jsonl"
_sw_cost_isolated "$_bl_dir4" breakdown "$_r_first" "p1" "" --render >/dev/null 2>&1 || true
_r_2nd="$TEST_TEMP_DIR/boot-2"; mkdir -p "$_r_2nd"
printf '{"stage":"plan","input_tokens":1000,"output_tokens":100,"cost_usd":5.00,"model":"sonnet","ts":"%s","ts_epoch":1,"issue":""}\n' \
    "$_now2" > "$_r_2nd/stage-costs.jsonl"
_render_boot=$(_sw_cost_isolated "$_bl_dir4" breakdown "$_r_2nd" "p2" "" --render --no-update-baseline 2>&1) || true
# After 1 prior run (n=1 → bootstrap window <3), should not be HIGH.
# Match the data row only (grep by stage name "plan") to avoid the legend
# footer ("HIGH = >1.5× stage avg") triggering a false positive.
_boot_plan_row=$(echo "$_render_boot" | grep -E '│ plan ' || true)
if [[ -n "$_boot_plan_row" ]] && echo "$_boot_plan_row" | grep -qE 'HIGH|↑'; then
    assert_fail "bootstrap: n<3 should NOT flag HIGH (avoids alarm fatigue)" \
        "row: $_boot_plan_row"
elif [[ -z "$_boot_plan_row" ]]; then
    assert_fail "bootstrap: plan data row missing from render output" \
        "output: $(echo "$_render_boot" | head -10)"
else
    assert_pass "bootstrap: n<3 returns NORMAL even with 50× cost"
fi

# ── Test: --render-plain produces no ANSI escape codes ─────────────────────
_bl_dir5="$TEST_TEMP_DIR/baselines-5"
_r_pl="$TEST_TEMP_DIR/plain"; mkdir -p "$_r_pl"
printf '{"stage":"build","input_tokens":1000,"output_tokens":100,"cost_usd":0.10,"model":"sonnet","ts":"%s","ts_epoch":1,"issue":""}\n' \
    "$_now2" > "$_r_pl/stage-costs.jsonl"
_render_plain=$(_sw_cost_isolated "$_bl_dir5" breakdown "$_r_pl" "p" "" --render-plain 2>&1) || true
# ANSI ESC is hex 1b; check it's absent in the rendered table portion
if echo "$_render_plain" | grep -q $'\x1b\['; then
    assert_fail "render-plain: contains ANSI escape codes" "output: $(echo "$_render_plain" | head -5 | od -c | head -3)"
else
    assert_pass "render-plain: no ANSI escape codes (GitHub-comment safe)"
fi

# ── Test: baseline rejects negative cost / invalid input ────────────────────
# Source baselines.sh directly to test the validation function.
(
    export SW_BASELINE_DIR="$TEST_TEMP_DIR/baselines-validation"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/cost/baselines.sh"
    if baseline_update_stage "build" "-1.50" "100" "10" "" 2>/dev/null; then
        assert_fail "baseline: rejects negative cost"
    else
        assert_pass "baseline: rejects negative cost (validation works)"
    fi
    if baseline_update_stage "build" "abc" "100" "10" "" 2>/dev/null; then
        assert_fail "baseline: rejects non-numeric cost"
    else
        assert_pass "baseline: rejects non-numeric cost"
    fi
    if baseline_update_stage "../../etc/passwd" "0.10" "100" "10" "" 2>/dev/null; then
        assert_fail "baseline: rejects stage name with path traversal"
    else
        assert_pass "baseline: rejects stage name with path traversal chars"
    fi
)

# ── Test: HIGH/LOW classification across ≥5 historical runs (#504 T5) ──────
# Acceptance criterion T5 requires HIGH/LOW flags to be correct after at least
# five historical breakdowns have rolled into the baseline. This exercises the
# rolling-avg/classification path beyond the n=3 bootstrap window.
_bl_dir_t5="$TEST_TEMP_DIR/baselines-t5"
# 5 runs at 0.10, 0.20, 0.30, 0.40, 0.50 → rolling avg = 0.30 exactly
_t5_idx=1
for _cost in "0.100" "0.200" "0.300" "0.400" "0.500"; do
    _r="$TEST_TEMP_DIR/t5-${_t5_idx}"; mkdir -p "$_r"
    printf '{"stage":"build","input_tokens":1000,"output_tokens":100,"cost_usd":%s,"model":"sonnet","ts":"%s","ts_epoch":1,"issue":""}\n' \
        "$_cost" "$_now2" > "$_r/stage-costs.jsonl"
    _sw_cost_isolated "$_bl_dir_t5" breakdown "$_r" "t5-${_t5_idx}" "" --render >/dev/null 2>&1 || true
    _t5_idx=$((_t5_idx + 1))
done
_t5_n=$(jq '.stages.build.n' "$_bl_dir_t5/stage-costs.json" 2>/dev/null || echo "")
_t5_avg=$(jq '.stages.build.avg_usd' "$_bl_dir_t5/stage-costs.json" 2>/dev/null || echo "")
if [[ "$_t5_n" == "5" ]] && awk -v a="$_t5_avg" 'BEGIN {exit !(a >= 0.29 && a <= 0.31)}'; then
    assert_pass "T5: rolling avg across 5 runs (0.10..0.50) ≈ 0.30 (n=5)"
else
    assert_fail "T5: rolling avg across 5 runs ≈ 0.30" "n=${_t5_n} avg=${_t5_avg}"
fi

# 6th run at 0.60 → 2× of 0.30 avg → HIGH (>1.5×)
_r_t5_hi="$TEST_TEMP_DIR/t5-hi"; mkdir -p "$_r_t5_hi"
printf '{"stage":"build","input_tokens":1000,"output_tokens":100,"cost_usd":0.600,"model":"sonnet","ts":"%s","ts_epoch":1,"issue":""}\n' \
    "$_now2" > "$_r_t5_hi/stage-costs.jsonl"
_render_t5_hi=$(_sw_cost_isolated "$_bl_dir_t5" breakdown "$_r_t5_hi" "t5-hi" "" --render --no-update-baseline 2>&1) || true
if echo "$_render_t5_hi" | grep -E '│ build ' | grep -qE 'HIGH|↑'; then
    assert_pass "T5: 6th run at 2× rolling avg correctly flagged HIGH (n=5 baseline)"
else
    assert_fail "T5: 6th run at 2× rolling avg flagged HIGH" \
        "row: $(echo "$_render_t5_hi" | grep -E '│ build ')"
fi

# 6th run at 0.10 → 0.33× of 0.30 avg → LOW (<0.5×)
_r_t5_lo="$TEST_TEMP_DIR/t5-lo"; mkdir -p "$_r_t5_lo"
printf '{"stage":"build","input_tokens":1000,"output_tokens":100,"cost_usd":0.100,"model":"sonnet","ts":"%s","ts_epoch":1,"issue":""}\n' \
    "$_now2" > "$_r_t5_lo/stage-costs.jsonl"
_render_t5_lo=$(_sw_cost_isolated "$_bl_dir_t5" breakdown "$_r_t5_lo" "t5-lo" "" --render --no-update-baseline 2>&1) || true
if echo "$_render_t5_lo" | grep -E '│ build ' | grep -qE 'low|↓'; then
    assert_pass "T5: 6th run at 0.33× rolling avg correctly flagged LOW (n=5 baseline)"
else
    assert_fail "T5: 6th run at 0.33× rolling avg flagged LOW" \
        "row: $(echo "$_render_t5_lo" | grep -E '│ build ')"
fi

# 6th run at 0.30 → exactly avg → NORMAL (no flag)
_r_t5_nm="$TEST_TEMP_DIR/t5-nm"; mkdir -p "$_r_t5_nm"
printf '{"stage":"build","input_tokens":1000,"output_tokens":100,"cost_usd":0.300,"model":"sonnet","ts":"%s","ts_epoch":1,"issue":""}\n' \
    "$_now2" > "$_r_t5_nm/stage-costs.jsonl"
_render_t5_nm=$(_sw_cost_isolated "$_bl_dir_t5" breakdown "$_r_t5_nm" "t5-nm" "" --render --no-update-baseline 2>&1) || true
_t5_nm_row=$(echo "$_render_t5_nm" | grep -E '│ build ' || true)
if [[ -n "$_t5_nm_row" ]] && ! echo "$_t5_nm_row" | grep -qE 'HIGH|↑|low|↓'; then
    assert_pass "T5: 6th run at exactly rolling avg classified NORMAL (no false flag)"
else
    assert_fail "T5: NORMAL classification at exactly avg" "row: $_t5_nm_row"
fi

# ── Test: per-issue baseline isolation ──────────────────────────────────────
_bl_dir6="$TEST_TEMP_DIR/baselines-6"
_r_iss="$TEST_TEMP_DIR/iss-test"; mkdir -p "$_r_iss"
printf '{"stage":"build","input_tokens":1000,"output_tokens":100,"cost_usd":0.50,"model":"sonnet","ts":"%s","ts_epoch":1,"issue":"42"}\n' \
    "$_now2" > "$_r_iss/stage-costs.jsonl"
_sw_cost_isolated "$_bl_dir6" breakdown "$_r_iss" "p" "42" --render >/dev/null 2>&1 || true
if [[ -f "$_bl_dir6/issue-42-costs.json" && -f "$_bl_dir6/stage-costs.json" ]]; then
    assert_pass "baseline: per-issue file (issue-42-costs.json) created alongside all-issues"
else
    assert_fail "baseline: per-issue file created" "ls: $(ls "$_bl_dir6" 2>&1)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
