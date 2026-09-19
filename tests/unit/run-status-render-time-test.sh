#!/usr/bin/env bash
# tests/unit/run-status-render-time-test.sh — #2145: the run-status comment
# leads with WHEN, in the reader's zone, and says when the 6-hour ceiling is.
#
#   SPEC-1 [change]: a row starts with its start → end time, then seq + stage
#   SPEC-2 [change]: times are Eastern by default ("9:39 PM ET"), DST-aware;
#                    ZBUILD_STATUS_TZ overrides the zone
#   SPEC-3 [change]: the header carries the ceiling (start + 360 min) and the
#                    time left, or "past ceiling"
#   SPEC-4 [change]: a cancelled result finalizes the comment with the
#                    ceiling explanation and how to resume
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-status comment — time first, Eastern, ceiling (#2145)"
setup_test_env "run-status-render-time"

# shellcheck source=../../scripts/lib/run-status-render.sh
source "$REPO_ROOT/scripts/lib/run-status-render.sh"

STATE="$TEST_TEMP_DIR/state"; mkdir -p "$STATE/artifacts"
unset ZBUILD_STATUS_TZ ZBUILD_STATUS_NOW 2>/dev/null || true

# ─── SPEC-1 / SPEC-2: rows ───────────────────────────────────────────────────
print_test_section "1/2. a row leads with its times, in Eastern"
_row_running='{"key":"6.1.4","seq":"6.1.4","stage":"test","kind":"","started_ts":"2026-09-19T01:39:45Z","ended_ts":null,"verdict":null,"rc":null,"summaries":null,"resolve":null}'
_row_done='{"key":"6.1.4","seq":"6.1.4","stage":"test","kind":"","started_ts":"2026-09-19T01:39:45Z","ended_ts":"2026-09-19T02:38:01Z","verdict":"fail","rc":"1","summaries":null,"resolve":null}'
_r1="$(rsc_render_row "$STATE" "$_row_running")"
_r2="$(rsc_render_row "$STATE" "$_row_done")"
case "$_r1" in "**9:39 PM ET → running**"*) assert_pass "[SPEC-1] a running row starts with its start time and 'running'" ;;
    *) assert_fail "[SPEC-1] a running row starts with its start time and 'running'" "$_r1" ;; esac
case "$_r2" in "**9:39 PM ET → 10:38 PM ET (58m16s)**"*) assert_pass "[SPEC-1] a finished row starts with start → end (duration)" ;;
    *) assert_fail "[SPEC-1] a finished row starts with start → end (duration)" "$_r2" ;; esac
assert_contains "[SPEC-1] seq + stage follow the time, still bold" "$_r2" "· **6.1.4 test** · iter 1 · **fail rc=1**"
# DST: 2026-01-19T01:39:45Z is January → EST, still labelled ET, 8:39 PM.
_row_jan='{"key":"3","seq":"3","stage":"plan","kind":"","started_ts":"2026-01-19T01:39:45Z","ended_ts":null,"verdict":null,"rc":null,"summaries":null,"resolve":null}'
case "$(rsc_render_row "$STATE" "$_row_jan")" in "**8:39 PM ET → running**"*) assert_pass "[SPEC-2] January renders in EST, labelled ET" ;;
    *) assert_fail "[SPEC-2] January renders in EST, labelled ET" "$(rsc_render_row "$STATE" "$_row_jan")" ;; esac
_r_utc="$(ZBUILD_STATUS_TZ=UTC rsc_render_row "$STATE" "$_row_running")"
case "$_r_utc" in "**1:39 AM UTC → running**"*) assert_pass "[SPEC-2] ZBUILD_STATUS_TZ=UTC renders UTC" ;;
    *) assert_fail "[SPEC-2] ZBUILD_STATUS_TZ=UTC renders UTC" "$_r_utc" ;; esac

# ─── SPEC-3: header ceiling ──────────────────────────────────────────────────
print_test_section "3. the header says when the ceiling is and how long is left"
_model='{"header":{"run_id":"r-2145","issue":"1840","engine_sha":"b203477bdeadbeef","engine_branch":"main","started":"2026-09-19T01:16:58Z"},"rows":{},"order":[],"terminal":{},"pr":{}}'
_h="$(ZBUILD_STATUS_NOW=2026-09-19T05:56:00Z rsc_render_header "$_model" "$STATE")"
assert_contains "[SPEC-3] started is Eastern" "$_h" "started 9:16 PM ET"
assert_contains "[SPEC-3] the ceiling is start + 360 min" "$_h" "ceiling 3:16 AM ET"
assert_contains "[SPEC-3] …with the time left" "$_h" "(1h 20m left)"
_h2="$(ZBUILD_STATUS_NOW=2026-09-19T07:30:00Z rsc_render_header "$_model" "$STATE")"
assert_contains "[SPEC-3] after the ceiling it says so" "$_h2" "(past ceiling)"
_h3="$(ZBUILD_STATUS_NOW=2026-09-19T05:56:00Z ZBUILD_STATUS_CEILING_MIN=120 rsc_render_header "$_model" "$STATE")"
assert_contains "[SPEC-3] the ceiling minutes are configurable" "$_h3" "ceiling 11:16 PM ET"

# ─── SPEC-4: cancelled → finalized text ─────────────────────────────────────
print_test_section "4. a cancelled result finalizes the header with the ceiling line"
if declare -F rsc_finalize_body >/dev/null 2>&1; then
    _body="$(printf '%s\n### zbuild run `r-2145` · issue #1840 · **running**\nengine `b203477` (`main`) · started 9:16 PM ET\ncurrent: **9.2.2 spec-correspondence**\n**1:07 AM ET → running** · **9.2.2 spec-correspondence** · iter 2\n' "${_RSC_MARKER_PREFIX}r-2145 -->")"
    _fin="$(rsc_finalize_body "$_body" cancelled)"
    assert_contains "[SPEC-4] the status becomes cancelled at the ceiling" "$_fin" "**cancelled at the 360-minute ceiling**"
    assert_contains "[SPEC-4] …and says how to resume" "$_fin" "state persisted — re-add \`zbuild-run\` to resume"
    if grep -q '^current:' <<< "$_fin"; then assert_fail "[SPEC-4] no 'current:' line once finished" "$_fin"; else assert_pass "[SPEC-4] no 'current:' line once finished"; fi
    _fin_ok="$(rsc_finalize_body "$_body" success)"
    assert_contains "[SPEC-4] success finalizes as success" "$_fin_ok" "**success**"
else
    assert_fail "[SPEC-4] rsc_finalize_body exists" "function not defined"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
