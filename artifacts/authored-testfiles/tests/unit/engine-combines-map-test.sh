#!/usr/bin/env bash
# tests/unit/engine-combines-map-test.sh — the engine sums up a map group and
# tells later stages whether any member failed (#2368 part 2, ADR-040).
#
# Why: review-aggregator was a stage whose job was to combine the lenses'
# results into one report — the engine's job. Every later stage already sees
# each lens's own output; what is left for the engine is the group's summary
# and one word for the stages that act on it (pr-delivery's merge policy).
#
#   M1 [change] after a map group the engine writes <group>-summary.md: every
#               element, its outcome and its one-line reason
#   M2 [change] ZBUILD_RUN_FLAGGED is yes when an element failed, no otherwise
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the engine sums up a map group (#2368 part 2)"
setup_test_env "engine-combines-map"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR/artifacts"
STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
jq -n '{schema_version:1, stage_statuses:{}}' > "$STATE_FILE"
# shellcheck source=../../core/pipeline/strategies/map.sh
source "$REPO_ROOT/core/pipeline/strategies/map.sh"
# shellcheck source=../../core/pipeline/strategies/common.sh
source "$REPO_ROOT/core/pipeline/strategies/common.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

PLUGINS_ROOT="$REPO_ROOT/plugins"
ART="$ZBUILD_STATE_DIR/artifacts"
# Each work unit "runs" its lens: `b` finds a problem, the others pass.
orch_spawn()    { return 0; }
orch_dispatch() {
    local _e; _e="$(/usr/bin/grep -m1 "^export ZBUILD_REVIEW_LENS_ID=" "$2" | sed "s/^export ZBUILD_REVIEW_LENS_ID='//;s/'$//")"
    if [[ "$_e" == b ]]; then stage_result_write "$ART/lens-$_e.json" fail "a high problem the change introduced"
    else stage_result_write "$ART/lens-$_e.json" pass "nothing found"; fi
    printf 'slot\n'
}
orch_collect()  { return 0; }
orch_shutdown() { return 0; }
resolve_plugin_for_role() { echo "$PLUGINS_ROOT/agent/review-lens"; }
_check_artifact_contract() { return 0; }

_run_map() {
    declare -ga _MAP_DIM_lenses=("$@")
    unset ZBUILD_RUN_FLAGGED
    _strategy_run_map "pool-m" "review_lenses" "review_lens" "$STATE_FILE" "$PLUGINS_ROOT" \
        "lenses" "ZBUILD_REVIEW_LENS_ID" 4 continue >/dev/null 2>&1
}

print_test_section "M1: the group's summary"
_run_map a b c
S="$ART/review_lenses-summary.md"
assert_file_exists "[M1] the engine writes the group's summary" "$S"
assert_contains "[M1] each element, its outcome and its reason" "$(cat "$S" 2>/dev/null)" "- b: fail — a high problem the change introduced"
assert_contains "[M1] ...every one" "$(cat "$S" 2>/dev/null)" "- c: pass — nothing found"

print_test_section "M2: the engine's word for later stages"
assert_eq "[M2] an element failed → ZBUILD_RUN_FLAGGED=yes" "yes" "${ZBUILD_RUN_FLAGGED:-unset}"
rm -f "$ART"/lens-*.json
_run_map a c
assert_eq "[M2] none failed → ZBUILD_RUN_FLAGGED=no" "no" "${ZBUILD_RUN_FLAGGED:-unset}"

print_test_section "#1753/SPEC-1: any non-pass outcome sets ZBUILD_RUN_FLAGGED"
# Requirement: _strategy_run_map exports ZBUILD_RUN_FLAGGED=yes when ANY member
# has an outcome that is not `pass`. The old code only checked `outcome == fail`;
# unfinished outcomes (timed_out, out_of_turns, interrupted) were not flagged.
# New code: `outcome != pass` → flagged=yes.
#
# Three distinct non-pass outcomes are tested so that an implementation
# hard-coding one specific value (e.g. only timed_out) cannot pass all three.

# sub-test: timed_out — lens ran out of time
orch_dispatch() {
    local _e; _e="$(/usr/bin/grep -m1 "^export ZBUILD_REVIEW_LENS_ID=" "$2" | sed "s/^export ZBUILD_REVIEW_LENS_ID='//;s/'$//")"
    if [[ "$_e" == b ]]; then stage_result_write "$ART/lens-$_e.json" timed_out "lens ran out of time"
    else stage_result_write "$ART/lens-$_e.json" pass "nothing found"; fi
    printf 'slot\n'
}
rm -f "$ART"/lens-*.json
_run_map a b c
assert_eq "[#1753/SPEC-1] timed_out outcome → ZBUILD_RUN_FLAGGED=yes" "yes" "${ZBUILD_RUN_FLAGGED:-unset}"

# sub-test: out_of_turns — lens exhausted its turn budget
orch_dispatch() {
    local _e; _e="$(/usr/bin/grep -m1 "^export ZBUILD_REVIEW_LENS_ID=" "$2" | sed "s/^export ZBUILD_REVIEW_LENS_ID='//;s/'$//")"
    if [[ "$_e" == b ]]; then stage_result_write "$ART/lens-$_e.json" out_of_turns "lens exhausted turn budget"
    else stage_result_write "$ART/lens-$_e.json" pass "nothing found"; fi
    printf 'slot\n'
}
rm -f "$ART"/lens-*.json
_run_map a b c
assert_eq "[#1753/SPEC-1] out_of_turns outcome → ZBUILD_RUN_FLAGGED=yes" "yes" "${ZBUILD_RUN_FLAGGED:-unset}"

# sub-test: interrupted — lens was stopped by an outside signal
orch_dispatch() {
    local _e; _e="$(/usr/bin/grep -m1 "^export ZBUILD_REVIEW_LENS_ID=" "$2" | sed "s/^export ZBUILD_REVIEW_LENS_ID='//;s/'$//")"
    if [[ "$_e" == b ]]; then stage_result_write "$ART/lens-$_e.json" interrupted "lens was stopped by signal"
    else stage_result_write "$ART/lens-$_e.json" pass "nothing found"; fi
    printf 'slot\n'
}
rm -f "$ART"/lens-*.json
_run_map a b c
assert_eq "[#1753/SPEC-1] interrupted outcome → ZBUILD_RUN_FLAGGED=yes" "yes" "${ZBUILD_RUN_FLAGGED:-unset}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
