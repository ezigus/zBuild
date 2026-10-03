#!/usr/bin/env bash
# tests/unit/unit-name-test.sh — every unit that runs has its own name, and two
# units with one name never start together (#1706, ADR-054 §3.1).
#
# Why: a `map:` group hands every member the group's stage name. #2032 run
# 37066151065: the correctness and red-team lenses both timed out, the router
# named its error record from the stage alone (`review_lenses-sync-error`), and
# the second lens's record overwrote the first — red-team's diagnosis was lost.
# Decision (2026-10-03): each member gets its own name at run time, everything a
# member writes or emits is named from it, and a check refuses two units with
# one name at the same time. The group id stays where template settings are
# looked up.
#
# U1 [change] a map member's unit name is <stage>.<element>, for a declared
#             dimension and for platforms alike
# U2 [guard]  a dispatch outside a map is named by its stage alone
# U3 [change] the name lives for one dispatch: a stage dispatched from inside a
#             member is named by its own stage, and nothing is left set after
# U4 [change] an engine event emitted inside a member carries its unit name;
#             an event outside a map carries no `unit` key (envelope unchanged)
# U5 [change] two members' router error records have different file names
# U6 [change] a map whose members would share a name is refused before any
#             member starts, and the refusal names the duplicate
# U7 [change] a map with two roles runs every role on every element: each unit
#             is named <stage>.<role>.<element>, so all of them run, each with
#             its own name
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every unit has its own name (#1706)"
setup_test_env "unit-name"
unset ZBUILD_CURRENT_STAGE ZBUILD_UNIT ZBUILD_MAP_ELEMENT ZBUILD_MAP_DIMENSION 2>/dev/null || true

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/state-root"
export ZBUILD_RUN_ID="unit-name-test"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/strategies/map.sh
source "$REPO_ROOT/core/pipeline/strategies/map.sh"

# A plugin that records the name it ran under, and can dispatch a nested stage.
SEEN="$TEST_TEMP_DIR/seen.txt"; : > "$SEEN"
P="$TEST_TEMP_DIR/plugins/tool/namer"; mkdir -p "$P"
printf 'id: namer\nkind: tool\nversion: 0.0.1\nhooks:\n  run: namer_run\n' > "$P/manifest.yaml"
{
    printf '_NM_SEEN=%q\n_NM_DIR=%q\n' "$SEEN" "$P"
    cat <<'PLUG'
namer_run() {
    printf '%s=%s\n' "${ZBUILD_CURRENT_STAGE:-}" "${ZBUILD_UNIT-<unset>}" >> "$_NM_SEEN"
    if [[ "${NAMER_NEST:-0}" == "1" && "${ZBUILD_CURRENT_STAGE:-}" != "inner" ]]; then
        NAMER_NEST=0 plugin_hook_call "$_NM_DIR" run inner "$2"
    fi
    return 0
}
PLUG
} > "$P/plugin.sh"
SF="$ZBUILD_STATE_DIR/pipeline-state.json"; printf '{}\n' > "$SF"

_unit_of() {   # _unit_of <stage> → the unit name the plugin saw for that stage
    grep -E "^$1=" "$SEEN" | tail -1 | cut -d= -f2-
}

print_test_section "U1: map members are <stage>.<element>"
wu="$(_strategy_make_work_unit "$P" review_lenses "$SF" generic correctness lenses)"
bash "$wu" >/dev/null 2>&1; rm -f "$wu"
assert_eq "[U1] a lens member is review_lenses.correctness" "review_lenses.correctness" "$(_unit_of review_lenses)"
wu="$(_strategy_make_work_unit "$P" build_matrix "$SF" ios)"
bash "$wu" >/dev/null 2>&1; rm -f "$wu"
assert_eq "[U1] a platform member is build_matrix.ios" "build_matrix.ios" "$(_unit_of build_matrix)"

print_test_section "U2: outside a map, the stage name"
( plugin_hook_call "$P" run plan "$SF" ) >/dev/null 2>&1
assert_eq "[U2] a plain dispatch is named by its stage" "plan" "$(_unit_of plan)"

print_test_section "U3: the name lives for one dispatch"
wu="$(_strategy_make_work_unit "$P" review_lenses "$SF" generic red-team lenses)"
NAMER_NEST=1 bash "$wu" >/dev/null 2>&1; rm -f "$wu"
assert_eq "[U3] the member is review_lenses.red-team" "review_lenses.red-team" "$(_unit_of review_lenses)"
assert_eq "[U3] a stage dispatched inside it is named by its own stage" "inner" "$(_unit_of inner)"
( plugin_hook_call "$P" run plan "$SF" >/dev/null 2>&1; printf '%s' "${ZBUILD_UNIT-<unset>}" ) > "$TEST_TEMP_DIR/after"
assert_eq "[U3] nothing is left set after the dispatch" "<unset>" "$(cat "$TEST_TEMP_DIR/after")"

print_test_section "U4: events carry the unit name"
: > "$ZBUILD_EVENTS_JSONL"
wu="$(_strategy_make_work_unit "$P" review_lenses "$SF" generic security lenses)"
bash "$wu" >/dev/null 2>&1; rm -f "$wu"
assert_eq "[U4] the member's plugin.run.start names its unit" "review_lenses.security" \
    "$(jq -r 'select(.type=="plugin.run.start") | .unit // empty' "$ZBUILD_EVENTS_JSONL" | tail -1)"
assert_eq "[U4] ...and keeps the group as its stage" "review_lenses" \
    "$(jq -r 'select(.type=="plugin.run.start") | .stage // empty' "$ZBUILD_EVENTS_JSONL" | tail -1)"
: > "$ZBUILD_EVENTS_JSONL"
( plugin_hook_call "$P" run plan "$SF" ) >/dev/null 2>&1
assert_eq "[U4] an event outside a map has no unit key" "absent" \
    "$(jq -r 'select(.type=="plugin.run.start") | if has("unit") then "present" else "absent" end' "$ZBUILD_EVENTS_JSONL" | tail -1)"

print_test_section "U5: each member's router error record is its own file"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh" >/dev/null 2>&1 || true
_a="$(ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_UNIT=review_lenses.correctness _route_sync_diag_base 2>/dev/null)"
_b="$(ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_UNIT=review_lenses.red-team _route_sync_diag_base 2>/dev/null)"
assert_eq "[U5] the correctness lens's record" "review_lenses.correctness-sync-error" "$_a"
if [[ -n "$_a" && "$_a" != "$_b" ]]; then
    assert_pass "[U5] two members' records never share a file"
else
    assert_fail "[U5] two members' records never share a file" "'$_a' vs '$_b'"
fi

print_test_section "U6: a duplicate name is refused before anything starts"
DISPATCHED="$TEST_TEMP_DIR/dispatched"; : > "$DISPATCHED"
# shellcheck disable=SC2329  # called by the strategy
orch_spawn()    { mkdir -p "${TMPDIR:-/tmp}/zbuild-pool-$1/results" "${TMPDIR:-/tmp}/zbuild-pool-$1/pids"; return 0; }
# shellcheck disable=SC2329
orch_dispatch() { printf '%s\n' "$2" >> "$DISPATCHED"; printf 'slot-001\n'; return 0; }
# shellcheck disable=SC2329
orch_collect()  { return 0; }
# shellcheck disable=SC2329
orch_shutdown() { return 0; }
# shellcheck disable=SC2329
resolve_plugin_for_role() { printf '%s\n' "$P"; }
# shellcheck disable=SC2034  # read by the strategy by name
_MAP_DIM_lenses=(correctness security correctness)
: > "$ZBUILD_EVENTS_JSONL"
_strategy_run_map "pool-u6" review_lenses review_lens "$SF" "$TEST_TEMP_DIR/plugins" lenses >/dev/null 2>&1; _rc=$?
if [[ $_rc -ne 0 && $_rc -ne 3 ]]; then
    assert_pass "[U6] the map is refused (rc=$_rc)"
else
    assert_fail "[U6] the map is refused" "rc=$_rc"
fi
assert_eq "[U6] no member started" "0" "$(grep -c . "$DISPATCHED" || true)"
assert_contains "[U6] the refusal names the duplicate" \
    "$(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null)" "review_lenses.correctness"

print_test_section "U7: a map with two roles names each unit by role too"
# Dispatch for real, so each member reports the name it ran under.
# shellcheck disable=SC2329
orch_dispatch() { printf '%s\n' "$2" >> "$DISPATCHED"; bash "$2" >/dev/null 2>&1 || true; printf 'slot-001\n'; return 0; }
: > "$DISPATCHED"; : > "$SEEN"
# shellcheck disable=SC2034
_MAP_DIM_lenses=(correctness security)
_strategy_run_map "pool-u7" review_lenses $'lens_one\nlens_two' "$SF" "$TEST_TEMP_DIR/plugins" lenses >/dev/null 2>&1; _rc=$?
assert_eq "[U7] the two-role map runs" "0" "$_rc"
assert_eq "[U7] every role ran on every element" "4" "$(grep -c . "$DISPATCHED" || true)"
_names="$(grep -E '^review_lenses=' "$SEEN" | cut -d= -f2- | sort -u | tr '\n' ' ')"
assert_eq "[U7] each unit has its own name, role included" \
    "review_lenses.lens_one.correctness review_lenses.lens_one.security review_lenses.lens_two.correctness review_lenses.lens_two.security " "$_names"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
