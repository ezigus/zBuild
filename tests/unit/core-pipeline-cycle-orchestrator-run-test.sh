#!/usr/bin/env bash
# Tests: cycle_orchestrator_run end-to-end paths (ADR-021, #512)
# Drives the orchestrator with a mock cycle_dispatch_stage to hit:
#   - happy convergence path
#   - max_iterations
#   - plateau
#   - state init + atomic write
#   - state_init / write_iter helpers
# Lifts coverage on core/pipeline/cycle-orchestrator.sh toward ADR-021 §40% bar.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — orchestrator_run paths (ADR-021)"
setup_test_env "cycle-orch-run"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

FIXT="$REPO_ROOT/tests/fixtures/templates"
STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

_seed() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
}

# Mock hook scoped by global MOCK_VERDICTS map (stage→csv-of-verdicts)
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    local IFS_save="$IFS"; IFS=';'
    # shellcheck disable=SC2206
    local -a parts=($MOCK_VERDICTS); IFS="$IFS_save"
    local p sname vlist
    for p in "${parts[@]}"; do
        sname="${p%%:*}"; vlist="${p#*:}"
        if [[ "$sname" == "$stage" ]]; then
            IFS=','; # shellcheck disable=SC2206
            local -a vs=($vlist); IFS="$IFS_save"
            local idx=$(( iter - 1 ))
            [[ $idx -ge ${#vs[@]} ]] && idx=$(( ${#vs[@]} - 1 ))
            _CYCLE_DISPATCH_VERDICT="${vs[$idx]}"
            [[ "${vs[$idx]}" == "fail" ]] && _CYCLE_DISPATCH_STATUS="failed" || _CYCLE_DISPATCH_STATUS="complete"
            [[ "${vs[$idx]}" == "fail" ]] && return 1
            return 0
        fi
    done
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

# T1: bad args → rc=4
set +e; cycle_orchestrator_run "" "" ""; rc=$?; set -e
assert_eq "bad args → rc=4" "4" "$rc"

# T2: invalid cycle id (no template loaded) → rc=4
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
set +e; cycle_orchestrator_run "no-such-cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "unknown cycle id → rc=4 (config_invalid)" "4" "$rc"

# T3: converges on iter 1 → state contains cycle_iterations.status=complete
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
MOCK_VERDICTS="build:pass;test:pass"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "iter 1 converges → rc=0" "0" "$rc"
ci_status="$(jq -r '.cycle_iterations["build-test"].status' "$STATE_FILE")"
assert_eq "state.cycle_iterations.status=complete" "complete" "$ci_status"
iter_len="$(jq -r '.cycle_iterations["build-test"].iter | length' "$STATE_FILE")"
assert_eq "1 iter recorded in state" "1" "$iter_len"

# T4: max_iterations exhausted → rc=1 + history file populated
_seed
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_VERDICTS="build:pass,pass,pass;test:fail,fail,fail"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
# rc=1 (max_iter wins over plateau per ADR-021 priority order)
assert_eq "exhausted → rc=1" "1" "$rc"
hist="$ZBUILD_STATE_DIR/cycle-build-test-history.jsonl"
assert_file_exists "history file written" "$hist"
hl="$(wc -l < "$hist" | tr -d ' ')"
assert_eq "history has 3 rows" "3" "$hl"

# T5: cycle.iteration.complete emitted for every iter
ic="$(jq -r 'select(.type=="cycle.iteration.complete") | .type' "$ZBUILD_EVENTS_JSONL" | wc -l | tr -d ' ')"
assert_eq "3 cycle.iteration.complete events" "3" "$ic"

# T6: schema-additive — cycle_iterations key created when previously absent
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
MOCK_VERDICTS="build:pass;test:pass"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
keys="$(jq -r '.cycle_iterations | keys[]' "$STATE_FILE" 2>/dev/null)"
assert_contains "cycle_iterations key includes build-test" "$keys" "build-test"

# T7: record_iter_outcome writes JSONL row
H="$TEST_TEMP_DIR/h.jsonl"
: > "$H"
_CYCLE_TRAP_CYCLE_ID="t7"
set +e; _cycle_record_iter_outcome "$H" 1 "pass" "complete" 0; rc=$?; set -e
assert_eq "record_iter_outcome rc=0" "0" "$rc"
assert_file_exists "JSONL row file exists" "$H"
verdict="$(jq -r '.verdict' "$H")"
assert_eq "row verdict=pass" "pass" "$verdict"

# T8: handle_terminal_rc emits cycle.complete
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_LAST_ITERATIONS=2
_cycle_handle_terminal_rc 0 "manual" "$STATE_FILE"
assert_event_emitted "cycle.complete on handle_terminal_rc" "$ZBUILD_EVENTS_JSONL" "cycle.complete"

# T9: signal handler emits cycle.aborted
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_CYCLE_ID="t9"; _CYCLE_TRAP_ITER=2
( _cycle_on_signal SIGTERM >/dev/null 2>&1; exit $? ) || true
assert_event_emitted "cycle.aborted on signal" "$ZBUILD_EVENTS_JSONL" "cycle.aborted"

# T10: state_init creates cycle_iterations[id] entry
_seed
set +e; _cycle_state_init "$STATE_FILE" "x1" "/tmp/h.jsonl" 4; rc=$?; set -e
assert_eq "state_init rc=0" "0" "$rc"
v="$(jq -r '.cycle_iterations["x1"].status' "$STATE_FILE")"
assert_eq "x1 status=in_progress" "in_progress" "$v"

# T11: write_iter_atomic appends to iter[]
set +e; _cycle_state_write_iter_atomic "$STATE_FILE" "x1" 1 "pass" "complete" 0 "complete"; rc=$?; set -e
assert_eq "write_iter rc=0" "0" "$rc"
ilen="$(jq -r '.cycle_iterations["x1"].iter | length' "$STATE_FILE")"
assert_eq "iter array has 1 entry" "1" "$ilen"

# T12: _CYCLE_TRAP_CYCLE_ID cleared at every top-level return path
# [SPEC-1]: cleared on success (convergence) path — fails at baseline where
#   the orchestrator leaves _CYCLE_TRAP_CYCLE_ID="build-test" on exit.
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
MOCK_VERDICTS="build:pass;test:pass"
_CYCLE_TRAP_CYCLE_ID=""
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc_t12a=$?; set -e
assert_eq "T12 success rc=0" "0" "$rc_t12a"
assert_eq "[SPEC-1] _CYCLE_TRAP_CYCLE_ID cleared after top-level success" "" "$_CYCLE_TRAP_CYCLE_ID"

# [SPEC-2]: cleared on config_invalid error path — _CYCLE_TRAP_CYCLE_ID is
#   written at line 1583 before the template check fails; without the fix it
#   remains "no-such-cycle" on exit.
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
_CYCLE_TRAP_CYCLE_ID=""
set +e; cycle_orchestrator_run "no-such-cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc_t12b=$?; set -e
assert_eq "T12 config_invalid rc=4" "4" "$rc_t12b"
assert_eq "[SPEC-2] _CYCLE_TRAP_CYCLE_ID cleared after config_invalid return" "" "$_CYCLE_TRAP_CYCLE_ID"

print_test_results
