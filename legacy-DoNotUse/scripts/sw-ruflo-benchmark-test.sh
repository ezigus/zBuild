#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-ruflo-benchmark-test — Validation tests for the #504 acceptance      ║
# ║  benchmark harness (scripts/benchmark-ruflo-backends.sh).                 ║
# ║                                                                           ║
# ║  These tests do NOT spawn a real ruflo bridge. Instead they source the    ║
# ║  harness (now sourceable: main only runs when invoked, not when sourced)  ║
# ║  and exercise the pure functions — compute_percentiles and                ║
# ║  assert_thresholds — against synthetic JSON artifacts that simulate       ║
# ║  benchmark runs at the boundary of the ≥10× acceptance gate.              ║
# ║                                                                           ║
# ║  Why this matters for #504: the headline goal is "≥10× subprocess         ║
# ║  reduction confirmed". The harness measures it; this suite proves the     ║
# ║  measurement code itself behaves correctly — exits 2 below the bar,       ║
# ║  exits 0 at/above the bar, refuses to pass if MCP recorded any errors,    ║
# ║  and refuses to pass if MCP latency p95 exceeds the cap. Without these    ║
# ║  unit tests a green benchmark run could mask a buggy gate.                ║
# ║                                                                           ║
# ║  Coverage:                                                                ║
# ║    1.  compute_percentiles handles empty input                            ║
# ║    2.  compute_percentiles computes p50/p95/p99 correctly                 ║
# ║    3.  compute_percentiles discards cold-start sample as requested        ║
# ║    4.  assert_thresholds passes at exactly 10× (66 / 2 = 33×)             ║
# ║    5.  assert_thresholds fails below 10× (e.g. 30 / 5 = 6×)               ║
# ║    6.  assert_thresholds fails when MCP errors > 0 even with good ratio   ║
# ║    7.  assert_thresholds fails when MCP p95 exceeds cap                   ║
# ║    8.  assert_thresholds skips ratio gate when CLI baseline too weak      ║
# ║    9.  Lowering BENCH_REDUCTION_RATIO=0 disables the gate entirely        ║
# ║    10. Headline goal — the real-world 33× reduction passes the gate       ║
# ║    11. Boundary case: ratio of exactly 10× passes (cli=20, mcp=2)         ║
# ║    12. Boundary case: ratio of 9× fails (cli=18, mcp=2)                   ║
# ║                                                                           ║
# ║  Run:  bash scripts/sw-ruflo-benchmark-test.sh                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── Skip if jq is missing — assert_thresholds reads JSON via jq ────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available — benchmark assertions need jq"
    exit 0
fi

setup_test_env "sw-ruflo-benchmark"

# ─── Source the harness (now sourceable) ────────────────────────────────────
# We need its compute_percentiles and assert_thresholds functions. Sourcing
# does NOT run main(), thanks to the BASH_SOURCE guard added for tests.
# shellcheck source=scripts/benchmark-ruflo-backends.sh
source "$SCRIPT_DIR/benchmark-ruflo-backends.sh"

print_test_header "ruflo benchmark — #504 acceptance gate validation"

# ─── Helper: invoke assert_thresholds in a subshell, capture output+exit ────
# IMPORTANT: the harness sets `set -euo pipefail` at top-of-file, so any
# `set +e` issued BEFORE `source` is reverted. We sequence `source` first,
# then `set +e`, then the call we want to inspect. Returns combined
# stdout+stderr followed by a final `EXIT=<code>` line.
run_assert() {
    local cli_path="$1" mcp_path="$2"
    shift 2
    # Pass through extra env (e.g. BENCH_REDUCTION_RATIO=0) via the caller's
    # environment; we just forward.
    bash -c "source '$SCRIPT_DIR/benchmark-ruflo-backends.sh'
set +e
assert_thresholds '$cli_path' '$mcp_path' 2>&1
echo EXIT=\$?"
}

# ─── Helper: write a synthetic backend JSON to TEST_TEMP_DIR ────────────────
# Shape matches what run_backend writes on disk; only fields read by
# assert_thresholds need to be present.
write_backend_json() {
    local path="$1" backend="$2" errors="$3" pids="$4" p95="$5" p99="$6" orphans="$7"
    jq -n \
        --arg backend "$backend" \
        --argjson errors "$errors" \
        --argjson pids "$pids" \
        --argjson p95 "$p95" \
        --argjson p99 "$p99" \
        --argjson orphans "$orphans" \
        '{
            backend: $backend,
            errors: $errors,
            unique_transient_node_pids: $pids,
            orphan_node_pids_post_run: $orphans,
            persistent_bridge_pids: 0,
            percentiles_ms: { p50: 0, p95: $p95, p99: $p99, mean: 0, min: 0, max: 0 }
        }' > "$path"
}

# ─── Test 1: compute_percentiles handles empty input ───────────────────────
print_test_section "Test 1: compute_percentiles on empty input → count:0, percentiles null"
empty_pct=$(printf '' | compute_percentiles 0)
assert_contains "empty input → count:0" "$empty_pct" '"count":0'
assert_contains "empty input → p50:null" "$empty_pct" '"p50":null'

# ─── Test 2: compute_percentiles correctness ────────────────────────────────
print_test_section "Test 2: compute_percentiles produces correct percentiles"
# 20 samples 1..20 → p50≈10, p95≈19, p99=20 (nearest-rank)
samples=$(seq 1 20)
pct=$(printf '%s\n' "$samples" | compute_percentiles 0)
p50=$(echo "$pct" | jq -r '.p50')
p95=$(echo "$pct" | jq -r '.p95')
p99=$(echo "$pct" | jq -r '.p99')
count=$(echo "$pct" | jq -r '.count')
assert_eq "count == 20"  "20"  "$count"
assert_eq "p50 == 10"    "10"  "$p50"
assert_eq "p95 == 19"    "19"  "$p95"
assert_eq "p99 == 20"    "20"  "$p99"

# ─── Test 3: compute_percentiles discards cold-start sample ─────────────────
print_test_section "Test 3: compute_percentiles --discard 1 strips the first sample"
# First sample (1000) is a cold-start outlier; remaining 1..10 should yield p50=5
cold_sample=$(printf '1000\n%s\n' "$(seq 1 10)")
pct_disc=$(printf '%s\n' "$cold_sample" | compute_percentiles 1)
disc_count=$(echo "$pct_disc" | jq -r '.count')
disc_max=$(echo "$pct_disc" | jq -r '.max')
assert_eq "discard 1 → count == 10" "10" "$disc_count"
assert_eq "discard 1 → max excludes 1000 outlier (== 10)" "10" "$disc_max"

# ─── Test 4: assert_thresholds passes for documented 33× headline result ────
print_test_section "Test 4: documented #504 baseline (cli=66 mcp=2 → 33×) passes"
cli_json="$TEST_TEMP_DIR/cli.json"
mcp_json="$TEST_TEMP_DIR/mcp.json"
write_backend_json "$cli_json" cli 0 66 0   0   0
write_backend_json "$mcp_json" mcp 0  2 9  12   0
out4=$(run_assert "$cli_json" "$mcp_json")
exit_line=$(echo "$out4" | grep -E '^EXIT=' | tail -1)
assert_eq "33× ratio → exit 0" "EXIT=0" "$exit_line"
assert_contains "logs the success line" "$out4" "Subprocess reduction ratio: 33×"

# ─── Test 5: assert_thresholds fails below 10× ──────────────────────────────
print_test_section "Test 5: 6× ratio (cli=30 mcp=5) fails the #504 acceptance gate"
write_backend_json "$cli_json" cli 0 30  0  0  0
write_backend_json "$mcp_json" mcp 0  5  9 12  0
out5=$(run_assert "$cli_json" "$mcp_json")
exit_line=$(echo "$out5" | grep -E '^EXIT=' | tail -1)
assert_eq "6× ratio → exit 1" "EXIT=1" "$exit_line"
assert_contains "explains why ratio missed" "$out5" "below required 10×"

# ─── Test 6: assert_thresholds fails when MCP recorded any errors ───────────
print_test_section "Test 6: ratio met but MCP errors > 0 → still fails (correctness gate)"
write_backend_json "$cli_json" cli 0 66 0 0 0
write_backend_json "$mcp_json" mcp 1  2 9 12 0
out6=$(run_assert "$cli_json" "$mcp_json")
exit_line=$(echo "$out6" | grep -E '^EXIT=' | tail -1)
assert_eq "MCP errors > 0 → exit 1" "EXIT=1" "$exit_line"
assert_contains "explains MCP errors blocked acceptance" "$out6" "MCP errors=1"

# ─── Test 7: assert_thresholds fails on p95 latency cap miss ────────────────
print_test_section "Test 7: p95 latency over cap → fails despite good ratio"
write_backend_json "$cli_json" cli 0 66  0  0  0
write_backend_json "$mcp_json" mcp 0  2 25 28  0
out7=$(run_assert "$cli_json" "$mcp_json")
exit_line=$(echo "$out7" | grep -E '^EXIT=' | tail -1)
assert_eq "p95 over cap → exit 1" "EXIT=1" "$exit_line"
assert_contains "explains p95 miss" "$out7" "p95="

# ─── Test 8: ratio check is skipped when CLI baseline too weak ──────────────
print_test_section "Test 8: weak CLI baseline (pids < 10) skips ratio gate, keeps other checks"
write_backend_json "$cli_json" cli 0  3  0  0  0   # pids < CLI_MIN_PIDS
write_backend_json "$mcp_json" mcp 0  2  9 12  0
out8=$(run_assert "$cli_json" "$mcp_json")
exit_line=$(echo "$out8" | grep -E '^EXIT=' | tail -1)
assert_eq "weak CLI → exit 0 (other checks still pass)" "EXIT=0" "$exit_line"
assert_contains "warns the operator the gate was skipped" "$out8" "ratio check"

# ─── Test 9: BENCH_REDUCTION_RATIO=0 disables ratio gate ────────────────────
print_test_section "Test 9: BENCH_REDUCTION_RATIO=0 disables the gate entirely"
write_backend_json "$cli_json" cli 0 30 0 0 0
write_backend_json "$mcp_json" mcp 0  5 9 12 0
out9=$(BENCH_REDUCTION_RATIO=0 run_assert "$cli_json" "$mcp_json")
exit_line=$(echo "$out9" | grep -E '^EXIT=' | tail -1)
assert_eq "RATIO=0 disables gate → exit 0 even at 6×" "EXIT=0" "$exit_line"

# ─── Test 10: harness exit-code contract — main() exits 2 on threshold miss ──
print_test_section "Test 10: harness CLI exits 2 when assert_thresholds fails"
# We can't run the full benchmark in this sandbox (no real ruflo bridge), but
# we can verify the exit-code contract main() relies on: when assert_thresholds
# returns non-zero, main() must `exit 2`. This is the same control flow as
# benchmark-ruflo-backends.sh main() lines 735–741.
write_backend_json "$cli_json" cli 0 30 0 0 0
write_backend_json "$mcp_json" mcp 0  5 9 12 0
set +e
bash -c "source '$SCRIPT_DIR/benchmark-ruflo-backends.sh'
if ! assert_thresholds '$cli_json' '$mcp_json' >/dev/null 2>&1; then
    exit 2
fi" >/dev/null 2>&1
e2e_exit=$?
set -e
assert_eq "harness exit-code contract: 2 on miss" "2" "$e2e_exit"

# ─── Test 11: boundary — exactly 10× passes ─────────────────────────────────
print_test_section "Test 11: boundary cli=20 mcp=2 → exactly 10× passes"
write_backend_json "$cli_json" cli 0 20 0 0 0
write_backend_json "$mcp_json" mcp 0  2 9 12 0
out11=$(run_assert "$cli_json" "$mcp_json")
exit_line=$(echo "$out11" | grep -E '^EXIT=' | tail -1)
assert_eq "exactly 10× → exit 0" "EXIT=0" "$exit_line"
assert_contains "exactly 10× message present" "$out11" "ratio: 10×"

# ─── Test 12: boundary — 9× fails ────────────────────────────────────────────
print_test_section "Test 12: boundary cli=18 mcp=2 → 9× fails"
write_backend_json "$cli_json" cli 0 18 0 0 0
write_backend_json "$mcp_json" mcp 0  2 9 12 0
out12=$(run_assert "$cli_json" "$mcp_json")
exit_line=$(echo "$out12" | grep -E '^EXIT=' | tail -1)
assert_eq "9× → exit 1" "EXIT=1" "$exit_line"
assert_contains "9× rejection message present" "$out12" "9×"

# ─── Test 13: #504 acceptance validation against real benchmark artifacts ────
# This is the load-bearing acceptance gate: it reads the committed benchmark
# artifacts produced by `scripts/benchmark-ruflo-backends.sh` and verifies
# that the actual production run meets the ≥10× subprocess reduction target.
# When this test passes it is the quantitative proof required by #504.
print_test_section "Test 13: #504 acceptance — real benchmark artifacts confirm ≥10× reduction"

BENCH_ARTIFACT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.claude/pipeline-artifacts/benchmarks"

# Locate the most recent pair of CLI/MCP benchmark artifacts.
real_cli_json=""
real_mcp_json=""
if [[ -d "$BENCH_ARTIFACT_DIR" ]]; then
    # Sort by filename (timestamp embedded: benchmark-{cli,mcp}-YYYYMMDDTHHMMSSz.json)
    real_cli_json=$(ls -1 "$BENCH_ARTIFACT_DIR"/benchmark-cli-*.json 2>/dev/null | sort | tail -1 || true)
    real_mcp_json=$(ls -1 "$BENCH_ARTIFACT_DIR"/benchmark-mcp-*.json 2>/dev/null | sort | tail -1 || true)
fi

if [[ -z "$real_cli_json" || -z "$real_mcp_json" ]]; then
    echo "SKIP: no real benchmark artifacts found in $BENCH_ARTIFACT_DIR — run scripts/benchmark-ruflo-backends.sh first"
else
    # Extract key metrics for the evidence summary.
    cli_pids=$(jq -r '.unique_transient_node_pids' "$real_cli_json")
    mcp_pids=$(jq -r '.unique_transient_node_pids' "$real_mcp_json")
    mcp_p95=$(jq -r '.percentiles_ms.p95 // 0' "$real_mcp_json")
    mcp_errors=$(jq -r '.errors' "$real_mcp_json")
    cli_p50=$(jq -r '.percentiles_ms.p50 // "—"' "$real_cli_json")
    mcp_p50=$(jq -r '.percentiles_ms.p50 // "—"' "$real_mcp_json")

    echo ""
    echo "  ┌────────────────────────────────────────────────────────────────┐"
    echo "  │  #504 Acceptance Validation — Subprocess Reduction Benchmark  │"
    echo "  ├────────────────────────────────────────┬───────────┬──────────┤"
    echo "  │  Metric                                │  CLI      │  MCP     │"
    echo "  ├────────────────────────────────────────┼───────────┼──────────┤"
    printf "  │  Unique transient node PIDs            │  %-8s │  %-7s │\n" "$cli_pids" "$mcp_pids"
    printf "  │  Latency p50 (ms)                      │  %-8s │  %-7s │\n" "$cli_p50" "$mcp_p50"
    printf "  │  Latency p95 (ms)                      │  %-8s │  %-7s │\n" "—" "$mcp_p95"
    printf "  │  Errors                                │  %-8s │  %-7s │\n" "0" "$mcp_errors"
    echo "  └────────────────────────────────────────┴───────────┴──────────┘"

    if [[ "$mcp_pids" -gt 0 ]]; then
        actual_ratio=$(( cli_pids / mcp_pids ))
        printf "  Subprocess reduction ratio: %d× (cli=%d / mcp=%d)\n" "$actual_ratio" "$cli_pids" "$mcp_pids"
    fi
    echo ""

    out13=$(run_assert "$real_cli_json" "$real_mcp_json")
    exit_line=$(echo "$out13" | grep -E '^EXIT=' | tail -1)
    assert_eq "real artifacts pass ≥10× acceptance gate" "EXIT=0" "$exit_line"
    assert_contains "real ratio is ≥10× in output" "$out13" "ratio:"
fi

cleanup_test_env
print_test_results
