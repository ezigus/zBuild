#!/usr/bin/env bash
# Tests: ADR-029 G2 — repeated-timeout fast abandon (#810)
#
# When a cycle member returns verdict=error reason=router_timeout (the value
# _router_rc_classify sets when claude rc=124 reaches the agent plugin —
# courtesy of ADR-021 R2 / PR #809), the orchestrator counts consecutive
# timeouts per-member. On the 2nd consecutive, it emits
# `cycle.member.timeout_abandoned` and terminates the cycle with
# _CYCLE_LAST_TERMINATED_REASON=timeout_abandoned (rc=4).
#
# The point is to STOP burning 900s budget on 3rd+ retries that the dogfood
# evidence shows are wasted. The reset on any non-timeout dispatch ensures
# transient hiccups don't trip the abandon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle G2 — repeated-timeout fast abandon (ADR-029)"
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

# Mock dispatch hook driven by a per-stage csv plan. Verdict values can be:
#   pass | fail | timeout (= sets verdict=error reason=router_timeout)
# A stage missing from the plan defaults to pass.
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    local IFS_save="$IFS"; IFS=';'
    # shellcheck disable=SC2206
    local -a parts=($MOCK_PLAN); IFS="$IFS_save"
    local p sname vlist v
    v="pass"
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
            _CYCLE_DISPATCH_VERDICT="error"
            _CYCLE_DISPATCH_VERDICT_RAW="error"
            _CYCLE_DISPATCH_STATUS="failed"
            _CYCLE_DISPATCH_REASON="router_timeout"
            return 124 ;;
        fail)
            _CYCLE_DISPATCH_VERDICT="fail"
            _CYCLE_DISPATCH_VERDICT_RAW="fail"
            _CYCLE_DISPATCH_STATUS="failed"
            _CYCLE_DISPATCH_REASON=""
            return 1 ;;
        *)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            _CYCLE_DISPATCH_STATUS="complete"
            _CYCLE_DISPATCH_REASON=""
            return 0 ;;
    esac
}

# ─── T1: 2 consecutive router_timeouts → fast abandon (rc=4) ─────────────────
_seed
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_PLAN="build:timeout,timeout,timeout;test:fail,fail,fail"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T1: 2nd consecutive timeout → rc=4 (terminate)" "4" "$rc"
assert_eq "T1: terminated_reason=timeout_abandoned" \
    "timeout_abandoned" "$_CYCLE_LAST_TERMINATED_REASON"

# Event audit: at least one cycle.member.timeout AND one cycle.member.timeout_abandoned.
ev_to="$(grep -c '"type":"cycle.member.timeout"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
if [[ "$ev_to" -ge 1 ]]; then
    assert_pass "T1: cycle.member.timeout emitted (count=$ev_to)"
else
    assert_fail "T1: no cycle.member.timeout event"
fi
ev_ab="$(grep -c '"type":"cycle.member.timeout_abandoned"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
if [[ "$ev_ab" -ge 1 ]]; then
    assert_pass "T1: cycle.member.timeout_abandoned emitted (count=$ev_ab)"
else
    assert_fail "T1: no cycle.member.timeout_abandoned event"
fi
# Iter 3 must NOT have run (we abandoned at iter 2).
n_iter="$(jq -r '.cycle_iterations["build-test"].iter | length' "$STATE_FILE")"
if [[ "$n_iter" -le 2 ]]; then
    assert_pass "T1: cycle terminated at iter ≤2 (no 3rd burn) — iter_count=$n_iter"
else
    assert_fail "T1: cycle ran $n_iter iters — did not fast-abandon"
fi

# ─── T2: single timeout then non-timeout → counter resets, full max_iter run ──
_seed
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_PLAN="build:timeout,fail,fail;test:fail,fail,fail"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
# `fail` resets the timeout counter; cycle exhausts max_iterations naturally.
assert_eq "T2: timeout + non-timeout → counter resets, rc=1 (max_iter)" "1" "$rc"
ev_ab="$(grep -c '"type":"cycle.member.timeout_abandoned"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
assert_eq "T2: no abandon when timeouts non-consecutive" "0" "$ev_ab"

# ─── T3: no timeouts at all → no event, normal cycle path ────────────────────
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
