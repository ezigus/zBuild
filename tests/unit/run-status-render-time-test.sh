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
    # #2166: the ceiling wording needs the clock to say so — started 6h before "now".
    _fin="$(ZBUILD_STATUS_NOW=2026-09-19T07:17:00Z rsc_finalize_body "$_body" cancelled 2026-09-19T01:16:58Z)"
    assert_contains "[SPEC-4] the status becomes cancelled at the ceiling" "$_fin" "**cancelled at the 360-minute ceiling**"
    assert_contains "[SPEC-4] …and says how to resume" "$_fin" "state persisted — re-add \`zbuild-run\` to resume"
    if grep -q '^current:' <<< "$_fin"; then assert_fail "[SPEC-4] no 'current:' line once finished" "$_fin"; else assert_pass "[SPEC-4] no 'current:' line once finished"; fi
    _fin_ok="$(rsc_finalize_body "$_body" success)"
    assert_contains "[SPEC-4] success finalizes as success" "$_fin_ok" "**success**"
    # review on #2146: finalizing twice (the runner already finished the
    # header, then post-run runs) must not append a second closing line.
    _fin2="$(ZBUILD_STATUS_NOW=2026-09-19T07:17:00Z rsc_finalize_body "$_fin" cancelled 2026-09-19T01:16:58Z)"
    assert_eq "[SPEC-4b] finalizing an already-finalized body is a no-op" "$_fin" "$_fin2"
    _fin3="$(rsc_finalize_body "$_fin_ok" cancelled)"
    assert_eq "[SPEC-4b] a body already marked success gains no cancelled closing line" \
        "0" "$(grep -c 're-add' <<< "$_fin3" || true)"
else
    assert_fail "[SPEC-4] rsc_finalize_body exists" "function not defined"
fi

# ─── SPEC-5 (#2166): an operator cancel is not "the ceiling" ────────────────
# #1840 run 8 was cancelled by hand at 8:34 PM with 3h 07m left, and the
# comment said "cancelled at the 360-minute ceiling". `cancelled` is what
# GitHub reports for both; the clock tells them apart.
print_test_section "5. a cancel well before the ceiling is an operator cancel"
if declare -F rsc_finalize_body >/dev/null 2>&1; then
    _body5="$(printf '%s\n### zbuild run `r-2166` · issue #1840 · **running**\nengine `b203477` (`main`) · started 5:41 PM ET\ncurrent: **6.2.4 test**\n' "${_RSC_MARKER_PREFIX}r-2166 -->")"
    # started 21:41Z, cancelled 00:34Z = 2h 53m in, ceiling 360m
    _early="$(ZBUILD_STATUS_NOW=2026-09-21T00:34:00Z rsc_finalize_body "$_body5" cancelled 2026-09-20T21:41:00Z)"
    assert_contains "[SPEC-5] a cancel 2h53m into a 6h ceiling is reported as an operator cancel" "$_early" "**cancelled by the operator ("
    assert_contains "[SPEC-5] …saying how far in" "$_early" "2h 53m in"
    assert_eq "[SPEC-5] …and never as the ceiling" "0" "$(grep -c 'minute ceiling' <<< "$_early" || true)"
    assert_contains "[SPEC-5] …and still says how to resume" "$_early" "re-add \`zbuild-run\` to resume"
    _late="$(ZBUILD_STATUS_NOW=2026-09-21T03:41:30Z rsc_finalize_body "$_body5" cancelled 2026-09-20T21:41:00Z)"
    assert_contains "[SPEC-5] a cancel at the ceiling is still the ceiling" "$_late" "**cancelled at the 360-minute ceiling**"
    _unk="$(rsc_finalize_body "$_body5" cancelled)"
    assert_contains "[SPEC-5] with no start time the wording stays neutral" "$_unk" "**cancelled**"
    assert_eq "[SPEC-5] …not the ceiling" "0" "$(grep -c 'minute ceiling' <<< "$_unk" || true)"
    if declare -F rsc_cancel_closing >/dev/null 2>&1; then
        _cl="$(ZBUILD_STATUS_NOW=2026-09-21T00:34:00Z rsc_cancel_closing 2026-09-20T21:41:00Z)"
        assert_contains "[SPEC-5] the post-run closing comment uses the same words" "$_cl" "cancelled by the operator"
    else
        assert_fail "[SPEC-5] rsc_cancel_closing <started_iso> exists for the workflow's closing comment" "function not defined"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
