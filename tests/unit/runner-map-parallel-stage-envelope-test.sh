#!/usr/bin/env bash
# Unit: core/pipeline/runner.sh — parallel:/map: stage envelope (ADR-039, ADR-047 §2)
#
# Verifies that the top-level dispatch loop in runner.sh emits stage.start /
# stage.complete, exports ZBUILD_CURRENT_STAGE, and writes stage_statuses /
# stage_verdicts for parallel: and map: dispatch units — behavior the baseline
# runner lacked entirely. Each [SPEC-n] assertion greps the actual runner.sh
# function body for the specific call added by this change; any assertion that
# names a variable unique to its dispatch arm (_pg_id vs _mg_id) cannot match
# any pre-existing code, so all 10 fail at the merge-base baseline.
#
# SPECs (all CHANGE — absent at baseline):
#   SPEC-1          parallel: arm emits stage.start
#   SPEC-2          parallel: arm emits stage.complete
#   SPEC-3          parallel: arm writes stage_statuses[id]=complete
#   SPEC-4          parallel: arm writes stage_verdicts[id]=pass
#   SPEC-5          parallel: arm exports ZBUILD_CURRENT_STAGE=id
#   SPEC-6          map: arm emits stage.start
#   SPEC-7          map: arm emits stage.complete
#   SPEC-8          map: arm writes stage_statuses[id]=complete
#   SPEC-9          map: arm writes stage_verdicts[id]=pass
#   SPEC-10         map: arm exports ZBUILD_CURRENT_STAGE=id
#   #1753/SPEC-4    map: arm checks ZBUILD_RUN_FLAGGED and returns 1 before _update_stage_status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER_SH="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner — parallel:/map: stage envelope (ADR-039, ADR-047 §2)"
setup_test_env "runner-map-parallel-stage-envelope"

# ═══════════════════════════════════════════════════════════════════════════════
# Part 1 — code-presence assertions on runner.sh
#
# These grep the ACTUAL runner.sh source for the specific calls the change adds.
# Variable names are arm-unique (_pg_id for parallel:, _mg_id for map:) so no
# pre-existing line can produce a false positive. All 10 fail at baseline.
# ═══════════════════════════════════════════════════════════════════════════════

# Extract the map: dispatch arm from runner.sh (~128 lines; widened from 115 by #1753
# which inserted a ~14-line ZBUILD_RUN_FLAGGED stop block before _update_stage_status).
MAP_ARM=$(awk '/[[:space:]]map:\*\)/{found=1; count=0} found{print; count++; if(count>=128){exit}}' \
    "$RUNNER_SH" 2>/dev/null || true)

print_test_section "1–5: parallel: arm envelope"

# SPEC-1
pg_start_hit=$(grep -cF 'eb_emit_event "stage.start" "stage=$_pg_id"' "$RUNNER_SH" 2>/dev/null) || pg_start_hit=0
assert_eq "[SPEC-1] parallel: dispatch arm emits stage.start" "1" "$pg_start_hit"

# SPEC-2
pg_complete_hit=$(grep -cF 'eb_emit_event "stage.complete" "stage=$_pg_id"' "$RUNNER_SH" 2>/dev/null) || pg_complete_hit=0
assert_eq "[SPEC-2] parallel: dispatch arm emits stage.complete" "1" "$pg_complete_hit"

# SPEC-3 — pattern is arm-unique: map: arm uses $_mg_id, so this only matches parallel: arm
pg_update_hit=$(grep -cF '_update_stage_status "$state_file" "$_pg_id"' "$RUNNER_SH" 2>/dev/null) || pg_update_hit=0
assert_eq "[SPEC-3] parallel: dispatch arm writes stage_statuses[id]=complete" "1" "$pg_update_hit"

# SPEC-4 — same uniqueness: $_pg_id only appears in the parallel: arm for verdict calls
pg_verdict_hit=$(grep -cF '_zbuild_state_set_stage_verdict "$state_file" "$_pg_id"' "$RUNNER_SH" 2>/dev/null) || pg_verdict_hit=0
assert_eq "[SPEC-4] parallel: dispatch arm writes stage_verdicts[id]=pass" "1" "$pg_verdict_hit"

# SPEC-5
pg_stage_var_hit=$(grep -cF 'export ZBUILD_CURRENT_STAGE="$_pg_id"' "$RUNNER_SH" 2>/dev/null) || pg_stage_var_hit=0
assert_eq "[SPEC-5] parallel: dispatch arm exports ZBUILD_CURRENT_STAGE=id" "1" "$pg_stage_var_hit"

print_test_section "6–10: map: arm envelope"

# SPEC-6
mg_start_hit=$(grep -cF 'eb_emit_event "stage.start" "stage=$_mg_id"' "$RUNNER_SH" 2>/dev/null) || mg_start_hit=0
assert_eq "[SPEC-6] map: dispatch arm emits stage.start" "1" "$mg_start_hit"

# SPEC-7
mg_complete_hit=$(grep -cF 'eb_emit_event "stage.complete" "stage=$_mg_id"' "$RUNNER_SH" 2>/dev/null) || mg_complete_hit=0
assert_eq "[SPEC-7] map: dispatch arm emits stage.complete" "1" "$mg_complete_hit"

# SPEC-8
assert_contains "[SPEC-8] map: dispatch arm writes stage_statuses[id]=complete" \
    "$MAP_ARM" '_update_stage_status'
assert_contains "[SPEC-8] map: _update_stage_status targets _mg_id" \
    "$MAP_ARM" '"$_mg_id"'

# SPEC-9
assert_contains "[SPEC-9] map: dispatch arm writes stage_verdicts[id]=pass" \
    "$MAP_ARM" '_zbuild_state_set_stage_verdict'

# SPEC-10
mg_stage_var_hit=$(grep -cF 'export ZBUILD_CURRENT_STAGE="$_mg_id"' "$RUNNER_SH" 2>/dev/null) || mg_stage_var_hit=0
assert_eq "[SPEC-10] map: dispatch arm exports ZBUILD_CURRENT_STAGE=id" "1" "$mg_stage_var_hit"

print_test_section "map: #1753 stop block"

# [#1753/SPEC-4]: when ZBUILD_RUN_FLAGGED=yes after _strategy_run_map, the map arm
# returns 1 before calling _update_stage_status for the group. Three assertions:
#   (a) static: ZBUILD_RUN_FLAGGED check appears before _update_stage_status in source
#   (b) static: return 1 is inside the ZBUILD_RUN_FLAGGED if-block
#   (c) runtime: with ZBUILD_RUN_FLAGGED=yes and _rc=0, _update_stage_status is not called

# (a) ZBUILD_RUN_FLAGGED check precedes _update_stage_status
spec4_pre_update=$(awk '/_update_stage_status.*_mg_id.*complete/{exit} {print}' <<< "$MAP_ARM")
spec4_flagged_cnt=$(grep -cF 'ZBUILD_RUN_FLAGGED:-' <<< "$spec4_pre_update") || spec4_flagged_cnt=0
assert_eq "[#1753/SPEC-4] map arm: ZBUILD_RUN_FLAGGED check precedes _update_stage_status" "1" "$spec4_flagged_cnt"

# (b) return 1 is inside the ZBUILD_RUN_FLAGGED if-block (not just anywhere in the arm)
# At baseline the block does not exist → spec4_flagged_if empty → count=0 ≠ 1 → FAILS.
# After #1753 the block is present with return 1 inside → count=1 → PASSES.
spec4_flagged_if=$(awk '
    /if \[\[.*ZBUILD_RUN_FLAGGED.*==.*yes/{p=1}
    p{print}
    p && /^[[:space:]]*fi/{p=0; exit}
' <<< "$spec4_pre_update")
spec4_return_in_if=$(grep -c 'return 1' <<< "$spec4_flagged_if") || spec4_return_in_if=0
assert_eq "[#1753/SPEC-4] map arm: return 1 inside ZBUILD_RUN_FLAGGED block" "1" "$spec4_return_in_if"

# (c) runtime: eval the code from "if [[ $_rc -ne 0 ]]" through _update_stage_status
#     with _rc=0 (so the rc-failure branch is skipped) and ZBUILD_RUN_FLAGGED=yes.
#     At baseline the arm has no stop block → reaches _update_stage_status → marker
#     created → assert_file_not_exists FAILS.
#     After #1753 the stop block fires return 1 before _update_stage_status → marker
#     absent → PASSES.
# Starts at the group's own rc check, after its complete event — not the
# orch_spawn check above it, whose code needs variables this harness lacks.
_spec4_rc_onward=$(awk '
    /parallel\.group\.complete/{seen=1}
    seen && /if \[\[.*_rc.*-ne.*0/{start=1}
    start{print}
    start && /_update_stage_status.*_mg_id.*complete/{exit}
' <<< "$MAP_ARM")
_spec4_marker="$TEST_TEMP_DIR/spec4_update_called"
rm -f "$_spec4_marker"
_spec4_runtime() {
    _set_pipeline_status()           { :; }
    _zbuild_state_set_stage_verdict() { :; }
    eb_emit_event()                  { :; }
    _render_pipeline_end()           { :; }
    error()                          { :; }
    _update_stage_status()           { [[ "$3" == complete ]] && touch "$_spec4_marker"; return 0; }
    state_file="$TEST_TEMP_DIR/state.json"
    _mg_id="review_lenses"
    _runner_run_id="run-001"
    _runner_issue="1753"
    _runner_ended=false
    _ZB_MAP_UNFINISHED=""
    _ZB_STRATEGY_OUTCOME="failed"
    _rc=0
    export ZBUILD_RUN_FLAGGED=yes
    eval "$_spec4_rc_onward"
}
set +e
( _spec4_runtime ) 2>/dev/null
set -e
assert_file_not_exists \
    "[#1753/SPEC-4] map arm: the group is not recorded complete when ZBUILD_RUN_FLAGGED=yes" \
    "$_spec4_marker"

# (d)–(f) #1753 lens review: the same code run both ways, recording what it does.
#   (d) every member passed (ZBUILD_RUN_FLAGGED=no) → the group completes (R4)
#   (e) a member did not pass → the group is recorded failed, and the stop
#       message names the members that did not pass
#   (f) the group's complete event takes its verdict from _map_group_verdict
_spec4_log="$TEST_TEMP_DIR/spec4_calls"
_spec4_run() {   # _spec4_run <flagged> <not_passed>
    : > "$_spec4_log"
    _spec4_body() {
        _set_pipeline_status()           { :; }
        _zbuild_state_set_stage_verdict() { printf 'verdict %s\n' "$3" >> "$_spec4_log"; }
        eb_emit_event()                  { :; }
        _render_pipeline_end()           { :; }
        error()                          { printf 'error %s\n' "$*" >> "$_spec4_log"; }
        _update_stage_status()           { printf 'status %s\n' "$3" >> "$_spec4_log"; }
        state_file="$TEST_TEMP_DIR/state.json"; _mg_id="review_lenses"
        _runner_run_id="run-001"; _runner_issue="1753"; _runner_ended=false
        _ZB_MAP_UNFINISHED=""; _ZB_MAP_NOT_PASSED="$2"; _ZB_STRATEGY_OUTCOME="failed"; _rc=0
        export ZBUILD_RUN_FLAGGED="$1"
        eval "$_spec4_rc_onward"
    }
    ( _spec4_body "$@" ) || true
}
_spec4_run no ""
assert_contains "[#1753/R4] every member passed → the group is recorded complete" "$(cat "$_spec4_log")" "status complete"
_spec4_run yes "1 of 6 lenses did not pass: correctness (fail)"
assert_contains "[#1753/R3] a member did not pass → the group is recorded failed" "$(cat "$_spec4_log")" "status failed"
assert_contains "[#1753/R3] … and the stop message names it" "$(cat "$_spec4_log")" "1 of 6 lenses did not pass: correctness (fail)"
# Static: the source passes _map_group_verdict to the event; M4 tests what it returns.
assert_contains "[#1753/R3] the group's complete event is emitted with _map_group_verdict (source check)" \
    "$(grep -A2 'parallel.group.complete' <<< "$MAP_ARM")" '_map_group_verdict'

# ═══════════════════════════════════════════════════════════════════════════════
# Part 2 — behavioral: state helpers write the expected values to a real JSON
# state file. Confirms the infrastructure that runner.sh now calls is correct.
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "B1: _update_stage_status writes stage_statuses[group]=complete"
STATE_FILE="$TEST_TEMP_DIR/state.json"
printf '{"schema_version":1,"stage_statuses":{},"stage_verdicts":{},"updated_at":"seed"}\n' \
    > "$STATE_FILE"

(
    export ZBUILD_STATE_DIR="$TEST_TEMP_DIR"
    # shellcheck source=../../core/state/atomic.sh
    source "$REPO_ROOT/core/state/atomic.sh"
    # shellcheck source=../../core/pipeline/state_helpers.sh
    source "$REPO_ROOT/core/pipeline/state_helpers.sh"
    _update_stage_status "$STATE_FILE" "review_group" "complete"
) 2>/dev/null
b1_status="$(jq -r '.stage_statuses.review_group // "missing"' "$STATE_FILE" 2>/dev/null || echo missing)"
assert_eq "B1: state_statuses[review_group]=complete written to state file" "complete" "$b1_status"

print_test_section "B2: _zbuild_state_set_stage_verdict writes stage_verdicts[group]=pass"
(
    export ZBUILD_STATE_DIR="$TEST_TEMP_DIR"
    # shellcheck source=../../core/state/atomic.sh
    source "$REPO_ROOT/core/state/atomic.sh"
    # shellcheck source=../../core/pipeline/state_helpers.sh
    source "$REPO_ROOT/core/pipeline/state_helpers.sh"
    _zbuild_state_set_stage_verdict "$STATE_FILE" "review_group" "pass"
) 2>/dev/null
b2_verdict="$(jq -r '.stage_verdicts.review_group // "missing"' "$STATE_FILE" 2>/dev/null || echo missing)"
assert_eq "B2: stage_verdicts[review_group]=pass written to state file" "pass" "$b2_verdict"

print_test_section "B3: stage_statuses covers all units including map and parallel groups"
# Simulate adding statuses for a leaf stage, a parallel group, and a map group —
# the three dispatch unit types that must appear in stage_statuses after a run.
printf '{"schema_version":1,"stage_statuses":{},"stage_verdicts":{},"updated_at":"seed"}\n' \
    > "$STATE_FILE"
(
    export ZBUILD_STATE_DIR="$TEST_TEMP_DIR"
    # shellcheck source=../../core/state/atomic.sh
    source "$REPO_ROOT/core/state/atomic.sh"
    # shellcheck source=../../core/pipeline/state_helpers.sh
    source "$REPO_ROOT/core/pipeline/state_helpers.sh"
    _update_stage_status "$STATE_FILE" "intake"        "complete"
    _update_stage_status "$STATE_FILE" "review_lenses" "complete"
    _update_stage_status "$STATE_FILE" "feature_work"  "complete"
) 2>/dev/null
for stage in intake review_lenses feature_work; do
    st="$(jq -r --arg s "$stage" '.stage_statuses[$s] // "missing"' "$STATE_FILE" 2>/dev/null || echo missing)"
    assert_eq "B3: stage_statuses includes $stage (covers all dispatch unit types)" "complete" "$st"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
