#!/usr/bin/env bash
# Integration tests: cycle blocked early-abort (#528).
#
# Drives cycle_orchestrator_run directly with mock cycle_dispatch_stage hook
# that emits verdict=error to trigger _cycle_detect_blocked. Verifies:
#   I1: error iter 1 → blocked at iter 1 (not 3); rc=5; reason=blocked
#   I2: fail-then-pass → converges normally (regression: blocked NOT on fail)
#   I3: cycle.blocked + cycle.complete reason=blocked emitted in order
#   I5: termination priority — until-pass + blocked simultaneous → converged wins
#   I7: regression — F1 fixtures still terminate with expected reasons
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — blocked early-abort integration (#528)"
setup_test_env "cycle-blocked-int"

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

_seed_state() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
}

# Programmable mock dispatch hook — reads $MOCK_VERDICTS, returns
# {pass=>rc 0, fail=>rc 1, error/corrupt_diff/block => rc 1, complete/failed status}
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    local IFS_save="$IFS"; IFS=';'
    # shellcheck disable=SC2206
    local -a parts=($MOCK_VERDICTS)
    IFS="$IFS_save"
    local p
    for p in "${parts[@]}"; do
        local sname="${p%%:*}" vlist="${p#*:}"
        if [[ "$sname" == "$stage" ]]; then
            IFS=','
            # shellcheck disable=SC2206
            local -a vs=($vlist)
            IFS="$IFS_save"
            local idx=$(( iter - 1 ))
            [[ $idx -ge ${#vs[@]} ]] && idx=$(( ${#vs[@]} - 1 ))
            local v="${vs[$idx]}"
            _CYCLE_DISPATCH_VERDICT="$v"
            case "$v" in
                pass) _CYCLE_DISPATCH_STATUS="complete"; return 0 ;;
                fail|error|corrupt_diff|block) _CYCLE_DISPATCH_STATUS="failed"; return 1 ;;
                *) _CYCLE_DISPATCH_STATUS="complete"; return 0 ;;
            esac
        fi
    done
    return 0
}

# ─── I1: verdict=error iter 1 → blocked at iter 1, rc=5, reason=blocked ─────
_seed_state
load_template "$FIXT/cycle-blocked.yaml"
MOCK_VERDICTS="build:pass,pass,pass,pass,pass;test:error,fail,fail,fail,fail"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "I1: orchestrator rc=5 (blocked)" "5" "$rc"
assert_eq "I1: terminated at iter 1 (no retry of structural error)" "1" "$_CYCLE_LAST_ITERATIONS"
assert_eq "I1: reason=blocked" "blocked" "$_CYCLE_LAST_TERMINATED_REASON"

# ─── I2: fail-then-pass → converges normally (regression) ───────────────────
_seed_state
load_template "$FIXT/cycle-converges-iter2.yaml"
MOCK_VERDICTS="build:pass,pass,pass;test:fail,pass"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "I2: fail-then-pass converges (NOT blocked on fail) rc=0" "0" "$rc"
assert_eq "I2: reason=converged (regression)" "converged" "$_CYCLE_LAST_TERMINATED_REASON"

# ─── I3: events emitted in order: iteration.complete → blocked → complete(blocked)
_seed_state
load_template "$FIXT/cycle-blocked.yaml"
MOCK_VERDICTS="build:pass;test:error"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "I3: rc=5 (blocked)" "5" "$rc"
assert_event_emitted "I3: cycle.blocked emitted" "$ZBUILD_EVENTS_JSONL" "cycle.blocked"
assert_event_emitted "I3: cycle.complete emitted" "$ZBUILD_EVENTS_JSONL" "cycle.complete"
# Check ordering: cycle.iteration.complete before cycle.blocked before cycle.complete(reason=blocked)
order_ok=1
ic_line="$(grep -n '"type":"cycle.iteration.complete"' "$ZBUILD_EVENTS_JSONL" | head -1 | cut -d: -f1)"
bl_line="$(grep -n '"type":"cycle.blocked"' "$ZBUILD_EVENTS_JSONL" | head -1 | cut -d: -f1)"
co_line="$(grep -n '"type":"cycle.complete".*"reason":"blocked"' "$ZBUILD_EVENTS_JSONL" | head -1 | cut -d: -f1)"
[[ -n "$ic_line" && -n "$bl_line" && -n "$co_line" ]] || order_ok=0
if [[ $order_ok -eq 1 ]]; then
    [[ "$ic_line" -lt "$bl_line" && "$bl_line" -lt "$co_line" ]] || order_ok=0
fi
if [[ $order_ok -eq 1 ]]; then
    assert_pass "I3: event order iteration.complete → blocked → complete(reason=blocked)"
else
    assert_fail "I3: event order" "ic=$ic_line bl=$bl_line co=$co_line"
fi
# cycle.blocked carries stage + verdict context
blocked_evt="$(grep '"type":"cycle.blocked"' "$ZBUILD_EVENTS_JSONL" | head -1)"
assert_contains "I3: cycle.blocked stage=test" "$blocked_evt" '"stage":"test"'
assert_contains "I3: cycle.blocked verdict=error" "$blocked_evt" '"verdict":"error"'

# ─── I5: termination priority — until-pass present alongside blocked → converged wins
# Construct: test=pass (until satisfied), build=error (would block). Until is
# checked FIRST in the ladder, so converged wins.
_seed_state
load_template "$FIXT/cycle-blocked.yaml"
MOCK_VERDICTS="build:error;test:pass"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "I5: until satisfied wins over blocked (rc=0)" "0" "$rc"
assert_eq "I5: reason=converged (priority check)" "converged" "$_CYCLE_LAST_TERMINATED_REASON"

# ─── I7: regression — existing F1 fixtures still terminate with expected reasons
_seed_state
load_template "$FIXT/cycle-converges-iter2.yaml"
MOCK_VERDICTS="build:pass;test:pass"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "I7a: cycle-converges-iter2 still converges rc=0" "0" "$rc"

_seed_state
load_template "$FIXT/cycle-plateau.yaml"
MOCK_VERDICTS="build:pass,pass,pass,pass,pass;test:fail,fail,fail,fail,fail"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
# #1208: plateau early-exit removed — the cycle runs to max_iterations and
# terminates by-severity (failing tests → rc=8), not the old plateau rc=2.
assert_eq "I7b: cycle-plateau runs to exhaustion, failing tests → rc=8 (#1208)" "8" "$rc"

print_test_results
