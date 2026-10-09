#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost share test — Validate cross-machine cost merging         ║
# ║  Issue #460 — cost-breakdown.json artifact upload/merge for optimization  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-helpers.sh disable=SC1091
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/baselines"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real jq — share.sh depends on it for aggregation
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export SW_BASELINE_DIR="$TEST_TEMP_DIR/home/.shipwright/baselines"
    export NO_GITHUB=true

    # Source the libs under test. helpers.sh provides info/warn/error/success
    # and emit_event used by share.sh; baselines.sh is required so
    # cost_apply_merged_to_baselines has a working baseline_update_stage.
    # shellcheck source=lib/helpers.sh disable=SC1091
    source "$SCRIPT_DIR/lib/helpers.sh"
    # shellcheck source=lib/cost/baselines.sh disable=SC1091
    source "$SCRIPT_DIR/lib/cost/baselines.sh"
    # shellcheck source=lib/cost/share.sh disable=SC1091
    source "$SCRIPT_DIR/lib/cost/share.sh"
}

_test_cleanup_hook() { cleanup_test_env; }

# Helper — write a synthetic cost-breakdown.json fixture.
# Usage: write_fixture <path> <stage1:in:out:cost> [<stage2:in:out:cost> ...]
# total_cost_usd is computed from the stage specs.
write_fixture() {
    local path="$1"; shift
    mkdir -p "$(dirname "$path")"
    local stages_json="["
    local first=1
    for spec in "$@"; do
        local stage in_tok out_tok cost
        stage=$(echo "$spec" | cut -d: -f1)
        in_tok=$(echo "$spec" | cut -d: -f2)
        out_tok=$(echo "$spec" | cut -d: -f3)
        cost=$(echo "$spec" | cut -d: -f4)
        [[ $first -eq 0 ]] && stages_json+=","
        first=0
        stages_json+=$(printf '{"stage":"%s","input_tokens":%s,"output_tokens":%s,"cost_usd":%s,"count":1,"models":["sonnet"]}' \
            "$stage" "$in_tok" "$out_tok" "$cost")
    done
    stages_json+="]"
    local total_cost
    total_cost=$(echo "$stages_json" | jq '[.[].cost_usd] | add')
    jq -n \
        --argjson stages "$stages_json" \
        --argjson total "$total_cost" \
        '{
            pipeline_id: "test",
            issue: "460",
            generated_at: "2026-05-19T00:00:00Z",
            summary: { total_cost_usd: $total, total_input_tokens: 0, total_output_tokens: 0, iteration_count: 0, stage_count: ($stages | length) },
            by_stage: $stages,
            by_iteration: []
        }' > "$path"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Cost Share (Cross-Machine Merge) Tests"
echo -e "${DIM}  ══════════════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: lib is sourceable and exports cost_merge_breakdowns ────────────
echo -e "${DIM}  library API surface${RESET}"
if type cost_merge_breakdowns >/dev/null 2>&1; then
    assert_pass "cost_merge_breakdowns is defined"
else
    assert_fail "cost_merge_breakdowns is defined"
fi
if type cost_apply_merged_to_baselines >/dev/null 2>&1; then
    assert_pass "cost_apply_merged_to_baselines is defined"
else
    assert_fail "cost_apply_merged_to_baselines is defined"
fi
if type cost_share_validate_breakdown >/dev/null 2>&1; then
    assert_pass "cost_share_validate_breakdown is defined"
else
    assert_fail "cost_share_validate_breakdown is defined"
fi

# Subshell source check (matches DoD: "sourceable in subshell")
if bash -c "source '$SCRIPT_DIR/lib/cost/share.sh' && type cost_merge_breakdowns" >/dev/null 2>&1; then
    assert_pass "share.sh sources cleanly in a fresh subshell"
else
    assert_fail "share.sh sources cleanly in a fresh subshell"
fi

# ─── Test 2: happy path — 3 valid breakdowns with overlapping stages ────────
echo ""
echo -e "${DIM}  happy path — 3 sources, overlapping stages${RESET}"

INPUT_DIR_1="$TEST_TEMP_DIR/merge1"
mkdir -p "$INPUT_DIR_1"

write_fixture "$INPUT_DIR_1/run-1/cost-breakdown.json" \
    "plan:1000:200:0.05" "build:5000:1000:0.25"
write_fixture "$INPUT_DIR_1/run-2/cost-breakdown.json" \
    "plan:2000:300:0.10" "test:1500:200:0.06"
write_fixture "$INPUT_DIR_1/run-3/cost-breakdown.json" \
    "plan:1500:250:0.08" "build:6000:1200:0.30" "review:800:100:0.04"

OUT_1="$TEST_TEMP_DIR/merged-1.json"
if cost_merge_breakdowns "$INPUT_DIR_1" "$OUT_1" >/dev/null 2>&1; then
    assert_pass "merge of 3 valid files returns 0"
else
    assert_fail "merge of 3 valid files returns 0"
fi

if [[ -f "$OUT_1" ]]; then
    assert_pass "merged file written"

    sources=$(jq -r '.sources' "$OUT_1")
    assert_eq "sources == 3" "3" "$sources"

    stage_count=$(jq -r '.summary.stage_count' "$OUT_1")
    assert_eq "merged stage_count == 4 (plan, build, test, review)" "4" "$stage_count"

    # plan appears in all 3 runs: 0.05 + 0.10 + 0.08 = 0.23
    plan_cost=$(jq -r '.by_stage[] | select(.stage=="plan") | .cost_usd' "$OUT_1")
    assert_eq "plan cost summed across 3 runs" "0.23" "$plan_cost"

    plan_in=$(jq -r '.by_stage[] | select(.stage=="plan") | .input_tokens' "$OUT_1")
    assert_eq "plan input_tokens summed (1000+2000+1500)" "4500" "$plan_in"

    plan_count=$(jq -r '.by_stage[] | select(.stage=="plan") | .count' "$OUT_1")
    assert_eq "plan count summed across 3 runs" "3" "$plan_count"

    # build appears in 2 runs: 0.25 + 0.30 = 0.55
    build_cost=$(jq -r '.by_stage[] | select(.stage=="build") | .cost_usd' "$OUT_1")
    assert_eq "build cost summed across 2 runs" "0.55" "$build_cost"

    # review only in run-3
    review_cost=$(jq -r '.by_stage[] | select(.stage=="review") | .cost_usd' "$OUT_1")
    assert_eq "review cost from single run" "0.04" "$review_cost"

    total=$(jq -r '.summary.total_cost_usd' "$OUT_1")
    # 0.05+0.25+0.10+0.06+0.08+0.30+0.04 = 0.88
    assert_eq "total_cost_usd summed across all stages" "0.88" "$total"
else
    assert_fail "merged file written"
fi

# ─── Test 3: malformed JSON file is skipped, valid files still merge ────────
echo ""
echo -e "${DIM}  graceful skip — 1 malformed JSON + 2 valid${RESET}"

INPUT_DIR_2="$TEST_TEMP_DIR/merge2"
mkdir -p "$INPUT_DIR_2/run-bad" "$INPUT_DIR_2/run-good-a" "$INPUT_DIR_2/run-good-b"
write_fixture "$INPUT_DIR_2/run-good-a/cost-breakdown.json" "plan:1000:200:0.10"
write_fixture "$INPUT_DIR_2/run-good-b/cost-breakdown.json" "build:5000:1000:0.40"
echo "{ not valid json :::" > "$INPUT_DIR_2/run-bad/cost-breakdown.json"

OUT_2="$TEST_TEMP_DIR/merged-2.json"
if cost_merge_breakdowns "$INPUT_DIR_2" "$OUT_2" >/dev/null 2>&1; then
    assert_pass "merge with 1 malformed file returns 0 (not fatal)"
else
    assert_fail "merge with 1 malformed file returns 0 (not fatal)"
fi
sources_2=$(jq -r '.sources' "$OUT_2" 2>/dev/null || echo "x")
assert_eq "malformed file skipped, 2 sources counted" "2" "$sources_2"
total_2=$(jq -r '.summary.total_cost_usd' "$OUT_2" 2>/dev/null)
assert_eq "total reflects only valid files (0.10+0.40)" "0.5" "$total_2"

# ─── Test 4: schema violation — missing summary.total_cost_usd is skipped ───
echo ""
echo -e "${DIM}  schema guard — missing summary.total_cost_usd is skipped${RESET}"

INPUT_DIR_3="$TEST_TEMP_DIR/merge3"
mkdir -p "$INPUT_DIR_3/run-noschema" "$INPUT_DIR_3/run-ok"
# Valid JSON but missing required summary field
echo '{"by_stage":[{"stage":"plan","cost_usd":0.50}]}' \
    > "$INPUT_DIR_3/run-noschema/cost-breakdown.json"
write_fixture "$INPUT_DIR_3/run-ok/cost-breakdown.json" "plan:1000:200:0.10"

OUT_3="$TEST_TEMP_DIR/merged-3.json"
cost_merge_breakdowns "$INPUT_DIR_3" "$OUT_3" >/dev/null 2>&1
sources_3=$(jq -r '.sources' "$OUT_3")
assert_eq "schema-invalid file skipped, only valid one counted" "1" "$sources_3"
total_3=$(jq -r '.summary.total_cost_usd' "$OUT_3")
assert_eq "total reflects only schema-valid file (0.10)" "0.1" "$total_3"

# Direct validator check
if cost_share_validate_breakdown "$INPUT_DIR_3/run-ok/cost-breakdown.json"; then
    assert_pass "validator accepts a well-formed file"
else
    assert_fail "validator accepts a well-formed file"
fi
if cost_share_validate_breakdown "$INPUT_DIR_3/run-noschema/cost-breakdown.json"; then
    assert_fail "validator rejects schema-incomplete file"
else
    assert_pass "validator rejects schema-incomplete file"
fi

# ─── Test 5: empty input dir → valid empty merged JSON ──────────────────────
echo ""
echo -e "${DIM}  edge case — empty input dir produces empty merged JSON${RESET}"

INPUT_DIR_4="$TEST_TEMP_DIR/merge4"
mkdir -p "$INPUT_DIR_4"
OUT_4="$TEST_TEMP_DIR/merged-4.json"
if cost_merge_breakdowns "$INPUT_DIR_4" "$OUT_4" >/dev/null 2>&1; then
    assert_pass "merge of empty dir returns 0"
else
    assert_fail "merge of empty dir returns 0"
fi
sources_4=$(jq -r '.sources' "$OUT_4")
assert_eq "empty dir merge has sources == 0" "0" "$sources_4"
total_4=$(jq -r '.summary.total_cost_usd' "$OUT_4")
assert_eq "empty dir merge has total_cost_usd == 0" "0" "$total_4"
by_stage_len=$(jq -r '.by_stage | length' "$OUT_4")
assert_eq "empty dir merge has empty by_stage[]" "0" "$by_stage_len"

# ─── Test 6: cost_apply_merged_to_baselines updates baseline file ───────────
echo ""
echo -e "${DIM}  baseline integration — merge → apply updates rolling baseline${RESET}"

# Use the well-formed merged file from Test 2
n_updated=$(cost_apply_merged_to_baselines "$OUT_1" 2>/dev/null | tail -1)
if [[ "$n_updated" =~ ^[0-9]+$ ]] && [[ "$n_updated" -ge 1 ]]; then
    assert_pass "apply_merged_to_baselines reports stages updated (n=$n_updated)"
else
    assert_fail "apply_merged_to_baselines reports stages updated" "got: $n_updated"
fi

BASELINE_FILE="$SW_BASELINE_DIR/stage-costs.json"
if [[ -f "$BASELINE_FILE" ]]; then
    assert_pass "baseline file was created"
    plan_n=$(jq -r '.stages.plan.n // 0' "$BASELINE_FILE")
    if [[ "$plan_n" -ge 1 ]]; then
        assert_pass "plan stage recorded in baseline (n=$plan_n)"
    else
        assert_fail "plan stage recorded in baseline" "n=$plan_n"
    fi
    plan_avg=$(jq -r '.stages.plan.avg_usd // 0' "$BASELINE_FILE")
    # Avg of plan = (0.23 total / 3 count) = 0.076666...
    # rolling average from initial 0 with n=1 should be ~0.0767
    if awk -v v="$plan_avg" 'BEGIN { exit !(v+0 > 0.06 && v+0 < 0.09) }'; then
        assert_pass "plan avg_usd in expected range (~0.077)"
    else
        assert_fail "plan avg_usd in expected range" "got: $plan_avg"
    fi
else
    assert_fail "baseline file was created"
fi

# ─── Test 7: invalid inputs handled gracefully ──────────────────────────────
echo ""
echo -e "${DIM}  defensive — missing/invalid inputs return non-zero${RESET}"

if cost_merge_breakdowns "" "/tmp/x.json" >/dev/null 2>&1; then
    assert_fail "merge with empty input_dir rejects"
else
    assert_pass "merge with empty input_dir rejects"
fi
if cost_merge_breakdowns "/nonexistent/path/should/not/exist" "/tmp/x.json" >/dev/null 2>&1; then
    assert_fail "merge with nonexistent input_dir rejects"
else
    assert_pass "merge with nonexistent input_dir rejects"
fi
if cost_apply_merged_to_baselines "" >/dev/null 2>&1; then
    assert_fail "apply with empty merged_file rejects"
else
    assert_pass "apply with empty merged_file rejects"
fi

# ─── Test 8: sw-cost.sh integration — sourceable, merge subcommand reachable ─
echo ""
echo -e "${DIM}  sw-cost.sh integration${RESET}"

if grep -q 'lib/cost/share.sh' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "sw-cost.sh sources lib/cost/share.sh"
else
    assert_fail "sw-cost.sh sources lib/cost/share.sh"
fi

# CLI: invoke `sw-cost.sh merge` with our test fixtures and verify output
OUT_CLI="$TEST_TEMP_DIR/cli-merged.json"
if bash "$SCRIPT_DIR/sw-cost.sh" merge "$INPUT_DIR_1" "$OUT_CLI" >/dev/null 2>&1; then
    assert_pass "sw-cost.sh merge subcommand exits 0"
else
    assert_fail "sw-cost.sh merge subcommand exits 0"
fi
if [[ -f "$OUT_CLI" ]]; then
    cli_sources=$(jq -r '.sources' "$OUT_CLI")
    assert_eq "CLI merge produces same sources count as library call" "3" "$cli_sources"
fi

print_test_results
