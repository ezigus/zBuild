#!/usr/bin/env bash
# Tests: ADR-029 G2 abandon REMOVED (#1208) — a repeated router timeout is NEVER
# fatal and NEVER abandons the cycle.
#
# History: ADR-029 G2 used to abandon the cycle (rc=4, reason=timeout_abandoned)
# on the 2nd consecutive router_timeout member dispatch. Issue #1208 reverses
# that: the ONLY fatal condition is the cycle exhausting max_iterations without a
# clean, passing convergence. A timed-out attempt simply consumes an iteration
# and the cycle retries; the by-severity cascade routes the EXHAUSTION outcome
# (tests failing → rc=8 halt; tests passing → rc=2 unconverged→review). The
# per-member timeout counter + G3 max_turns escalation are retained (see
# cycle-g3-maxturns-escalation-test.sh); only the abandon is gone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle G2 abandon removed — timeouts never abandon (#1208)"
setup_test_env "cycle-g2-timeout-abandon"

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

# Mock dispatch driven by a per-stage csv plan. Verdicts:
#   pass | fail | timeout (verdict=error reason=router_timeout, rc=124)
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    local IFS_save="$IFS"; IFS=';'
    # shellcheck disable=SC2206
    local -a parts=($MOCK_PLAN); IFS="$IFS_save"
    local p sname vlist v="pass"
    for p in "${parts[@]}"; do
        sname="${p%%:*}"; vlist="${p#*:}"
        if [[ "$sname" == "$stage" ]]; then
            IFS=','; # shellcheck disable=SC2206
            local -a vs=($vlist); IFS="$IFS_save"
            local idx=$(( iter - 1 ))
            [[ $idx -ge ${#vs[@]} ]] && idx=$(( ${#vs[@]} - 1 ))
            v="${vs[$idx]}"
            break
        fi
    done
    case "$v" in
        timeout)
            _CYCLE_DISPATCH_VERDICT="error"; _CYCLE_DISPATCH_VERDICT_RAW="error"
            _CYCLE_DISPATCH_STATUS="failed"; _CYCLE_DISPATCH_REASON="router_timeout"
            return 124 ;;
        fail)
            _CYCLE_DISPATCH_VERDICT="fail"; _CYCLE_DISPATCH_VERDICT_RAW="fail"
            _CYCLE_DISPATCH_STATUS="failed"; _CYCLE_DISPATCH_REASON=""
            return 1 ;;
        *)
            _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_VERDICT_RAW="pass"
            _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_REASON=""
            return 0 ;;
    esac
}

# ─── T1: repeated timeouts do NOT abandon — run to exhaustion, by-severity ───
_seed
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_PLAN="build:timeout,timeout,timeout;test:fail,fail,fail"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T1: NO abandon; exhausted with failing tests → rc=8 (by-severity)" "8" "$rc"
if [[ "$_CYCLE_LAST_TERMINATED_REASON" == "timeout_abandoned" ]]; then
    assert_fail "T1: reason is NOT timeout_abandoned (G2 removed)" "$_CYCLE_LAST_TERMINATED_REASON"
else
    assert_pass "T1: reason is not timeout_abandoned (got $_CYCLE_LAST_TERMINATED_REASON)"
fi
ev_ab="$(grep -c '"type":"cycle.member.timeout_abandoned"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
assert_eq "T1: no cycle.member.timeout_abandoned event (G2 abandon removed)" "0" "$ev_ab"
# All iterations ran — the cycle did NOT bail early at iter 2.
n_iter="$(jq -r '.cycle_iterations["build-test"].iter | length' "$STATE_FILE")"
assert_eq "T1: ran all max_iterations=3 (no early abandon)" "3" "$n_iter"
# The per-member timeout counter still increments (feeds G3) — event still emits.
ev_to="$(grep -c '"type":"cycle.member.timeout"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
[[ "$ev_to" -ge 1 ]] \
    && assert_pass "T1: cycle.member.timeout still emitted (counter retained for G3), count=$ev_to" \
    || assert_fail "T1: expected cycle.member.timeout for G3 accounting"

# ─── T2: timeouts but tests pass at exhaustion → soft-continue, never a halt ──
_seed
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_PLAN="build:timeout,timeout,timeout;test:pass,pass,pass"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_contains "T2: timeouts never fatal — rc is a soft-continue (0 or 2), not abandon(4)/halt(8)" \
    "0 2" "$rc"
ev_ab="$(grep -c '"type":"cycle.member.timeout_abandoned"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
assert_eq "T2: still no timeout_abandoned" "0" "$ev_ab"

# ─── T3: no timeouts at all → clean converge ─────────────────────────────────
_seed
load_template "$FIXT/cycle-converges-iter2.yaml"
MOCK_PLAN="build:pass;test:pass"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T3: clean run → rc=0 (converged)" "0" "$rc"
ev_to="$(grep -c '"type":"cycle.member.timeout"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
assert_eq "T3: clean run emits no timeout events" "0" "$ev_to"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
