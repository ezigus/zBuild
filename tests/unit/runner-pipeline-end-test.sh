#!/usr/bin/env bash
# Tests: core/pipeline/runner.sh — _render_pipeline_end terminal banner (#525)
#
# Covers the operator-visible banner emitted at every pipeline.end / EXIT-trap
# site. Verifies:
#   - per-status glyph + color resolution (delegates to verdict.sh helpers)
#   - NO_COLOR strips ANSI but preserves glyph + timestamp + status text
#   - unknown status falls back to '?' glyph defensively
#   - duration token honours ZBUILD_STAGE_IO_NOW_MS_OVERRIDE pin
#   - width degrade rule matches _render_stage_divider (mid_bar <= 2)
#
# ADR-015 §v5 amendment / ADR-006 pipeline status enum.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GOLDEN_DIR="$REPO_ROOT/tests/golden/pipeline-end"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/runner — pipeline.end terminal banner (#525)"
setup_test_env "runner-pipeline-end"

mkdir -p "$GOLDEN_DIR"

# Per-test isolation: subshell so runner.sh globals + helpers.sh palette
# re-init under the requested color mode.
emit_banner() {
    local mode="$1" status="$2" stage="${3:-}" rc="${4:-}" run_id="${5:-r1}" issue="${6:-83}"
    local env_pre=""
    if [[ "$mode" == "layout" ]]; then
        env_pre="unset FORCE_COLOR; export NO_COLOR=1"
    else
        env_pre="unset NO_COLOR; export FORCE_COLOR=1"
    fi
    bash -c "
        $env_pre
        export ZBUILD_TERM_WIDTH_OVERRIDE=80
        export ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
        export ZBUILD_STATE_DIR='$TEST_TEMP_DIR/state'
        export ZBUILD_EVENTS_DIR='$TEST_TEMP_DIR/events'
        export ZBUILD_EVENTS_JSONL='$TEST_TEMP_DIR/events/events.jsonl'
        mkdir -p \"\$ZBUILD_STATE_DIR\" \"\$ZBUILD_EVENTS_DIR\"
        source '$REPO_ROOT/core/pipeline/runner.sh'

        _runner_run_id='$run_id'
        _runner_issue='$issue'
        _RUNNER_PIPELINE_START_MS=12344600   # 400 ms before override -> '0.4s'
        _render_pipeline_end '$status' '$stage' '$rc'
    " 2>&1
}

# ─── T1: glyph + status text per status class (layout mode) ──────────────────
out="$(emit_banner layout complete)"
assert_contains "T1a complete banner uses ✓ glyph"        "$out" "✓"
assert_contains "T1a complete banner uses 'complete' word" "$out" "Pipeline complete:"
assert_contains "T1a complete banner carries status=complete" "$out" "status=complete"

out="$(emit_banner layout failed build 1)"
assert_contains "T1b failed banner uses ✗ glyph"  "$out" "✗"
assert_contains "T1b failed banner reports stage" "$out" "stage=build"
assert_contains "T1b failed banner reports rc"    "$out" "rc=1"

out="$(emit_banner layout interrupted)"
assert_contains "T1c interrupted banner uses ✗ glyph"   "$out" "✗"
assert_contains "T1c interrupted banner word"           "$out" "Pipeline interrupted:"

out="$(emit_banner layout aborted)"
assert_contains "T1d aborted banner uses ✗ glyph"  "$out" "✗"
assert_contains "T1d aborted banner word"          "$out" "Pipeline aborted:"

out="$(emit_banner layout preflight_failed)"
assert_contains "T1e preflight_failed banner uses ⚠ glyph"   "$out" "⚠"
assert_contains "T1e preflight_failed banner word tracks status" "$out" "Pipeline preflight_failed:"

# ─── T2: colored mode carries ANSI escapes per status class ──────────────────
out_c="$(emit_banner colored complete)"
# GREEN ANSI = 24-bit fg from stage-colors.sh ladder? helpers.sh:
#   GREEN='\033[38;2;0;255;102m'   (cf. helpers.sh §Colors)
# Just check for a SGR escape + verdict_color is non-empty in colored mode.
assert_contains "T2a colored complete carries an ANSI escape" "$out_c" $'\033['
out_c="$(emit_banner colored failed build 1)"
assert_contains "T2b colored failed carries an ANSI escape"   "$out_c" $'\033['
out_c="$(emit_banner colored preflight_failed)"
assert_contains "T2c colored preflight_failed carries an ANSI escape" "$out_c" $'\033['

# ─── T3: NO_COLOR strips ANSI but preserves glyph + timestamp + text ─────────
out_l="$(emit_banner layout complete)"
# Sanity: no ESC byte present at all
if [[ "$out_l" == *$'\033'* ]]; then
    assert_fail "T3 NO_COLOR strips ANSI" "ESC byte found in layout-mode banner"
else
    assert_pass "T3 NO_COLOR strips ANSI"
fi
assert_contains "T3 NO_COLOR keeps glyph"     "$out_l" "✓"
assert_contains "T3 NO_COLOR keeps timestamp" "$out_l" "UTC"
assert_contains "T3 NO_COLOR keeps frame"     "$out_l" "pipeline.end"

# ─── T4: unknown status falls back to '?' glyph defensively ──────────────────
out="$(emit_banner layout bogus_status)"
assert_contains "T4 unknown status uses '?' glyph"  "$out" "?"
assert_contains "T4 unknown status word echoes raw" "$out" "status=bogus_status"

# ─── T5: ZBUILD_STAGE_IO_NOW_MS_OVERRIDE pins the banner timestamp ───────────
#   override = 12345000 ms  →  03:25:45 UTC (matches stage-banner I1 fixture)
assert_contains "T5 timestamp pin → 03:25:45 UTC" "$out_l" "03:25:45 UTC"

# ─── T6: duration token derived from _RUNNER_PIPELINE_START_MS ───────────────
# Start cache = 12344600, now override = 12345000 → 400 ms → "0.4s"
assert_contains "T6 duration renders (took 0.4s)" "$out_l" "(took 0.4s)"

# ─── T7: cache-miss → duration degrades to '?s' (no crash) ───────────────────
out_miss="$(bash -c "
    unset FORCE_COLOR; export NO_COLOR=1
    export ZBUILD_TERM_WIDTH_OVERRIDE=80
    export ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
    export ZBUILD_STATE_DIR='$TEST_TEMP_DIR/state'
    export ZBUILD_EVENTS_DIR='$TEST_TEMP_DIR/events'
    export ZBUILD_EVENTS_JSONL='$TEST_TEMP_DIR/events/events.jsonl'
    source '$REPO_ROOT/core/pipeline/runner.sh'
    _runner_run_id=r9; _runner_issue=0
    _RUNNER_PIPELINE_START_MS=''
    _render_pipeline_end complete
" 2>&1)"
assert_contains "T7 cache-miss duration → '?s'" "$out_miss" "(took ?s)"

# ─── T8: width degrade rule (mid_bar <= 2) mirrors _render_stage_divider ─────
# label " pipeline.end " = 14 chars, ts "HH:MM:SS UTC" = 12 chars
# At width=20: left_bar = (20-14-12-1)/2 = -3, mid_bar = 20-(-3)-14-12-1 = -4 ≤2
out_narrow="$(bash -c "
    unset FORCE_COLOR; export NO_COLOR=1
    export ZBUILD_TERM_WIDTH_OVERRIDE=20
    export ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
    export ZBUILD_STATE_DIR='$TEST_TEMP_DIR/state'
    export ZBUILD_EVENTS_DIR='$TEST_TEMP_DIR/events'
    export ZBUILD_EVENTS_JSONL='$TEST_TEMP_DIR/events/events.jsonl'
    source '$REPO_ROOT/core/pipeline/runner.sh'
    _runner_run_id=r1; _runner_issue=83
    _RUNNER_PIPELINE_START_MS=12344600
    _render_pipeline_end complete
" 2>&1)"
# Degrade: header line MUST NOT contain the timestamp 03:25:45 (dropped in
# narrow-mode by the mid_bar<=2 check). Line 2 still renders normally.
header_line="$(echo "$out_narrow" | awk 'NR==2')"
if [[ "$header_line" == *"03:25:45"* ]]; then
    assert_fail "T8 narrow-width degrade drops header timestamp" \
                "header: $header_line"
else
    assert_pass "T8 narrow-width degrade drops header timestamp"
fi
assert_contains "T8 narrow-width still renders status line" "$out_narrow" "status=complete"

# ─── T9: paired goldens (5 statuses × layout + colored = 10 files) ───────────
declare -a STATUSES=(
    "complete"
    "failed"
    "interrupted"
    "aborted"
    "preflight_failed"
)
for status in "${STATUSES[@]}"; do
    stage=""
    rc=""
    [[ "$status" == "failed" ]] && stage="build" && rc="1"
    for mode in layout colored; do
        golden_file="$GOLDEN_DIR/${status}-w80.${mode}.txt"
        actual="$(emit_banner "$mode" "$status" "$stage" "$rc")"

        if [[ "${ZBUILD_REGEN_GOLDENS:-0}" == "1" ]]; then
            printf '%s' "$actual" > "$golden_file"
            assert_pass "REGEN: $(basename "$golden_file") rewritten"
            continue
        fi

        if [[ ! -f "$golden_file" ]]; then
            assert_fail "$(basename "$golden_file") missing" \
                "run with ZBUILD_REGEN_GOLDENS=1 to create"
            continue
        fi

        expected="$(cat "$golden_file")"
        if [[ "$actual" == "$expected" ]]; then
            assert_pass "byte-exact match: $(basename "$golden_file")"
        else
            assert_fail "byte-exact match: $(basename "$golden_file")" \
                "(rerun with ZBUILD_REGEN_GOLDENS=1 after intentional changes)"
            diff <(printf '%s' "$expected") <(printf '%s' "$actual") || true
        fi
    done
done

cleanup_test_env
print_test_results
exit "$FAIL"
