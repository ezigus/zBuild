#!/usr/bin/env bash
# tests/unit/monitor-hardening-test.sh — the monitor plugin's review fixes
# (issue #1847; PR #2221 lenses + claude-review + issue-acceptance).
#
# M1 [change] a turn-budget hit reaches monitor the way the router really
#             reports it — rc=1 with the budget marker, from inside `$( )` — and
#             is written as disposition out_of_turns / reason router_out_of_turns,
#             taken from router_reason_disposition (the rc=10 branch never ran)
# M2 [change] the interrupted and out_of_turns paths raise monitor.alert, like
#             every other failure path
# M3 [change] monitor restores the caller's own TERM/INT handlers, not the default
# M4 [change] an input resolving outside the run's state directory is refused
#             (disposition broken) and never read into the prompt
# M5 [change] results go to ZBUILD_ARTIFACT_DIR, never beside the state file
# M6 [change] no ZBUILD_ARTIFACT_DIR: rc=1 and a monitor.result.unwritable event
# M7 [change] missing arguments return 1, never 2 (rc ∈ {0,1}, ADR-054 §4b)
# M8 [change] no `jq … | atomic_write` pipe in plugin.sh (SIGPIPE rule)
# M9 [change] the interrupt bookkeeping does not leak into the caller's shell
# M10 [change] the WALL CLOCK block's elapsed time is measured from the start of
#              the stage, not from the line before it is printed
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "monitor plugin: review fixes (issue #1847)"
setup_test_env "monitor-hardening"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="monitor-hardening-$$" ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CURRENT_STAGE=monitor
mkdir -p "$ZBUILD_EVENTS_DIR"; : > "$ZBUILD_EVENTS_JSONL"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/monitor"
PLUGIN_FILE="$PLUGIN_DIR/plugin.sh"

# shellcheck source=../../plugins/agent/monitor/plugin.sh
source "$PLUGIN_FILE"

STATE_DIR="$TEST_TEMP_DIR/state"; ART="$STATE_DIR/artifacts"; STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$ART" "$STATE_DIR/stage-inputs"
printf '{"schema_version":1,"run_id":"t","issue":"1847"}\n' > "$STATE_FILE"
export ZBUILD_STATE_DIR="$STATE_DIR" ZBUILD_ARTIFACT_DIR="$ART"

MOCK_MODE=pass
PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
# The model call as the router really behaves: a turn-budget hit is rc=1 plus
# the marker (route.sh arms it); the variable dies in the caller's `$( )`.
# shellcheck disable=SC2329  # called by the sourced plugin
route_to_model() {
    printf '%s' "${2:-}" > "$PROMPT_FILE"
    case "$MOCK_MODE" in
        budget) _ROUTE_LAST_BUDGET_EXHAUSTED=1; _router_arm_budget_marker; return 1 ;;
        signal) kill -TERM "$MOCK_SIGNAL_PID"; sleep 1; return 130 ;;
        *)      printf '%s' '{"schema_version":1,"verdict":"pass","summary":"ok","checks":[]}' ;;
    esac
}
_rep() { jq -r "$1 // empty" "$ART/monitor-report.json" 2>/dev/null || true; }
_events() { cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null; }

print_test_section "M1/M2: the turn-budget path"
: > "$ZBUILD_EVENTS_JSONL"; rm -f "$ART/monitor-report.json"
MOCK_MODE=budget
_rc1=0; monitor_stage_run monitor "$STATE_FILE" >/dev/null 2>&1 || _rc1=$?
assert_eq "[M1] a budget hit → rc=1" "1" "$_rc1"
assert_eq "[M1] ...disposition out_of_turns" "out_of_turns" "$(_rep .disposition)"
assert_eq "[M1] ...reason router_out_of_turns (the classifier's word, not a hand-written one)" \
    "router_out_of_turns" "$(_rep .reason)"
if grep -qE '"\$rc"[[:space:]]*-eq[[:space:]]*10|rc[[:space:]]*-eq[[:space:]]*10' "$PLUGIN_FILE"; then
    assert_fail "[M1] no rc=10 branch remains (the router never returns 10)" "$(grep -nE 'eq[[:space:]]*10' "$PLUGIN_FILE")"
else
    assert_pass "[M1] no rc=10 branch remains (the router never returns 10)"
fi
assert_contains "[M2] the out_of_turns path raises monitor.alert" "$(_events)" "monitor.alert"

print_test_section "M2/M3/M9: the interrupted path"
: > "$ZBUILD_EVENTS_JSONL"; rm -f "$ART/monitor-report.json"
_m3_out="$(
    MOCK_MODE=signal
    MOCK_SIGNAL_PID=$BASHPID
    trap 'echo CALLER_TERM_HANDLER' TERM
    monitor_stage_run monitor "$STATE_FILE" >/dev/null 2>&1
    printf 'rc=%s\n' "$?"
    trap -p TERM
    printf 'leak_ref=%s leak_int=%s\n' "${_mon_out_ref-unset}" "${_mon_interrupted-unset}"
)"
assert_contains "[M2] the interrupted path raises monitor.alert" "$(_events)" "monitor.alert"
assert_eq "[M2] ...and records disposition interrupted" "interrupted" "$(_rep .disposition)"
assert_contains "[M3] the caller's TERM handler is back afterwards" "$_m3_out" "CALLER_TERM_HANDLER"
assert_contains "[M9] no interrupt bookkeeping leaks into the caller" "$_m3_out" "leak_ref=unset leak_int=unset"

print_test_section "M4: an input outside the run is refused"
_out4="$TEST_TEMP_DIR/elsewhere"; mkdir -p "$_out4"
printf '{"secret":"OUTSIDE-CONTENT"}\n' > "$_out4/deploy-result.json"
jq -n --arg d "$_out4/deploy-result.json" '{inputs:{deploy_result:$d}}' > "$STATE_DIR/stage-inputs/monitor.json"
: > "$ZBUILD_EVENTS_JSONL"; rm -f "$ART/monitor-report.json"; : > "$PROMPT_FILE"
MOCK_MODE=pass
_rc4=0; ZBUILD_STAGE_INPUTS="$STATE_DIR/stage-inputs/monitor.json" monitor_stage_run monitor "$STATE_FILE" >/dev/null 2>&1 || _rc4=$?
assert_eq "[M4] an input outside the state directory → rc=1" "1" "$_rc4"
assert_eq "[M4] ...disposition broken" "broken" "$(_rep .disposition)"
assert_contains "[M4] ...with a monitor.input.refused event" "$(_events)" "monitor.input.refused"
if grep -qF "OUTSIDE-CONTENT" "$PROMPT_FILE" 2>/dev/null; then
    assert_fail "[M4] ...and its content never reaches the prompt" "it did"
else
    assert_pass "[M4] ...and its content never reaches the prompt"
fi

print_test_section "M5/M6/M7: where results go"
_art5="$TEST_TEMP_DIR/engine-artifacts"; mkdir -p "$_art5" "$TEST_TEMP_DIR/elsewhere-state"
printf '{}' > "$TEST_TEMP_DIR/elsewhere-state/pipeline-state.json"
( export ZBUILD_ARTIFACT_DIR="$_art5" ZBUILD_DRY_RUN=1
  monitor_stage_run monitor "$TEST_TEMP_DIR/elsewhere-state/pipeline-state.json" ) >/dev/null 2>&1 || true
assert_file_exists "[M5] the report is written to ZBUILD_ARTIFACT_DIR" "$_art5/monitor-report.json"
if [[ -e "$TEST_TEMP_DIR/elsewhere-state/artifacts" ]]; then
    assert_fail "[M5] nothing is written beside the state file" "artifacts/ created there"
else
    assert_pass "[M5] nothing is written beside the state file"
fi
: > "$ZBUILD_EVENTS_JSONL"
_rc6=0; ( unset ZBUILD_ARTIFACT_DIR; monitor_stage_run monitor "$STATE_FILE" ) >/dev/null 2>&1 || _rc6=$?
assert_eq "[M6] no ZBUILD_ARTIFACT_DIR → rc=1" "1" "$_rc6"
assert_contains "[M6] ...and a monitor.result.unwritable event" "$(_events)" "monitor.result.unwritable"
_rc7=0; monitor_stage_run >/dev/null 2>&1 || _rc7=$?
assert_eq "[M7] missing arguments → rc=1, never 2" "1" "$_rc7"

print_test_section "M8: no pipe into atomic_write"
_m8="$(grep -nE '\|[[:space:]]*atomic_write' "$PLUGIN_FILE" 2>/dev/null || true)"
if [[ -n "$_m8" ]]; then assert_fail "[M8] plugin.sh has no '| atomic_write' pipe" "$_m8"
else assert_pass "[M8] plugin.sh has no '| atomic_write' pipe"; fi

print_test_section "M10: elapsed time is the stage's"
: > "$PROMPT_FILE"; MOCK_MODE=pass
( _llm_output_contract() { sleep 2; printf 'CONTRACT'; }
  _route_resolve_timeout() { printf '600'; }
  monitor_stage_run monitor "$STATE_FILE" ) >/dev/null 2>&1 || true
_el="$(grep -oE '~[0-9]+s have elapsed' "$PROMPT_FILE" | grep -oE '[0-9]+' || true)"
if [[ "${_el:-0}" =~ ^[0-9]+$ ]] && (( ${_el:-0} >= 2 )); then
    assert_pass "[M10] a stage that spent 2s before the call reports ≥2s elapsed (got ${_el})"
else
    assert_fail "[M10] a stage that spent 2s before the call reports ≥2s elapsed" "got ~${_el:-?}s"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
