#!/usr/bin/env bash
# tests/integration/unowned-finding-stale-test.sh — one `done` from anyone keeps
# a finding, and a leftover answer never counts (#2271). Split from
# unowned-finding-test.sh (#2310), which holds U1–U4 and U8.
#
# Why: the engine stops deciding who owns a finding; it only counts the answers
# stages give (Eric, 2026-10-04). If every build-side stage answers `nothing to
# do` to the same finding, the build loop ends early and the outer loop starts
# again at design, carrying every finding — no rule names design. If design also
# answers `nothing to do`, nobody owns it: the run stops with a report rather
# than circling. One `done` from anyone keeps a finding where it is.
#
# U5 [change] design disclaims it but a later outer-loop stage before the build
#             loop (impact) answers `done` → the run carries on: one `done`
#             from anyone keeps a finding (review #2291); the report written
#             when the last round ends lists impact's answer (#2330)
# U6 [change] an early hand-back is recorded as such in the loop's state, not
#             as rounds exhausted
# U7 [change] an answer left over from an earlier run or round never counts:
#             a stage that answers nothing this round does not disclaim — the
#             build loop runs again (review #2291 round 2; #2330: the last round
#             writes its own report, so the stop is read from the dispatches)
# U9 [change] the same for a map member's per-unit answer file
#             (<stage>.<element>.json) — review #2291 round 3
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a finding nobody owns: one done keeps it, a leftover answer never counts (#2271)"
setup_test_env "unowned-finding-stale"

# shellcheck source=../lib/unowned-finding-fixture.sh
source "$REPO_ROOT/tests/lib/unowned-finding-fixture.sh"

print_test_section "U5: a later outer-loop stage does the work"
TA="nothing to do" BUILD="nothing to do" DESIGN="nothing to do" IMPACT="done" _run
# #2330: the build loop hands the finding back again on the last round, so the
# report at the end lists it — with impact's `done` among the answers.
assert_contains "[U5] the end-of-run report shows impact's answer" \
    "$(cat "$ZBUILD_STATE_DIR/artifacts/unowned-findings.md" 2>/dev/null)" "impact: done"
assert_eq "[U5] the build loop runs again, from round 1" "2" "$(_count test_author 1)"

print_test_section "U6: the early hand-back is recorded as such"
TA="nothing to do" BUILD="nothing to do" DESIGN="done" _run
assert_eq "[U6] the build loop's state says it ended on an unowned finding" "unowned_finding" \
    "$(jq -r '.cycle_iterations.build_loop.status // empty' "$ZBUILD_STATE_DIR/pipeline-state.json" 2>/dev/null)"

print_test_section "U7: a leftover answer does not count"
# _run clears the answers directory, then this case leaves design's answer from
# an earlier run in place; design answers nothing this time.
_run_with_stale() {
    : > "$LOG"; : > "$ZBUILD_EVENTS_JSONL"
    rm -rf "$FA" "$ZBUILD_STATE_DIR/artifacts/unowned-findings.md" "$ZBUILD_STATE_DIR/artifacts/open-items.json" \
        "$ZBUILD_STATE_DIR/unowned-yield.json"
    _ans design "nothing to do" "left over from an earlier run"
    local sf="$ZBUILD_STATE_DIR/pipeline-state.json"
    rm -f "$sf" "$sf.bak" "$sf.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$sf"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$TPL" >/dev/null 2>&1 || return 99
    cycle_orchestrator_run outer_loop "$ZBUILD_STATE_DIR" "$sf" >/dev/null 2>&1
}
TA="nothing to do" BUILD="nothing to do" DESIGN="" IMPACT="nothing to do" _run_with_stale
# #2330: the report written on the last round is not this stop; the build loop
# running again in round 2 is what shows the leftover answer did not count.
assert_eq "[U7] not stopped — design said nothing this time: the build loop runs again" "2" "$(_count test_author 1)"

print_test_section "U9: a leftover per-unit answer does not count"
_run_with_stale_unit() {
    : > "$LOG"; : > "$ZBUILD_EVENTS_JSONL"
    rm -rf "$FA" "$ZBUILD_STATE_DIR/artifacts/unowned-findings.md" "$ZBUILD_STATE_DIR/artifacts/open-items.json" \
        "$ZBUILD_STATE_DIR/unowned-yield.json"
    mkdir -p "$FA"
    jq -nc '{"acc finding 1": {answer:"nothing to do", why:"left over", by:"design.unit"}}' > "$FA/design.unit.json"
    local sf="$ZBUILD_STATE_DIR/pipeline-state.json"
    rm -f "$sf" "$sf.bak" "$sf.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$sf"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$TPL" >/dev/null 2>&1 || return 99
    cycle_orchestrator_run outer_loop "$ZBUILD_STATE_DIR" "$sf" >/dev/null 2>&1
}
TA="nothing to do" BUILD="nothing to do" DESIGN="" IMPACT="nothing to do" _run_with_stale_unit
assert_eq "[U9] not stopped — the per-unit answer was left over: the build loop runs again" "2" "$(_count test_author 1)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
