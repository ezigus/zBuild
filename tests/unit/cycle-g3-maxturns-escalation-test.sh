#!/usr/bin/env bash
# Tests: ADR-029 G3 — per-stage max_turns escalation (#812)
#
# When a cycle member returns verdict=error reason=router_timeout, the
# orchestrator captures that member's base max_turns at the FIRST timeout
# and, on the NEXT dispatch of the same member, exports
# ZBUILD_ROUTER_MAX_TURNS_OVERRIDE with the escalated value (+50% rounded,
# capped at 2× base). The router's resolver checks this override before
# per-stage template / env / default.
#
# Composes with G2: 2nd consecutive timeout still abandons the cycle.
# Reset on success: a non-timeout dispatch clears both the counter and
# the captured base so future timeouts re-anchor from current budget.
#
# #2458: a stage with no turn limit keeps none. #1805 run 41489923219: build
# (max_turns: 0) timed out, G3 read its limit as the old default 25 and the
# next round ran with 37 turns — then ran out of them, and running out of turns
# stopped the run. T1/T3 now give the stage a limit (25) to escalate; T4 shows
# no limit stays no limit; T5 shows running out of turns does not stop the loop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "cycle G3 — max_turns escalation (ADR-029)"
setup_test_env "cycle-g3-maxturns"

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
    OBSERVED_OVERRIDES=()
}

# Dispatch mock: records ZBUILD_ROUTER_MAX_TURNS_OVERRIDE per call so we can
# verify the orchestrator escalated before invoking the stage. Verdicts are
# driven by MOCK_PLAN ("stage:csv" semicolon-joined; values: pass|fail|timeout).
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    OBSERVED_OVERRIDES+=("$stage:$iter:${ZBUILD_ROUTER_MAX_TURNS_OVERRIDE:-unset}")
    local IFS_save="$IFS"; IFS=';'
    # shellcheck disable=SC2206
    local -a parts=($MOCK_PLAN); IFS="$IFS_save"
    local p sname vlist v; v="pass"
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
        turns)
            _CYCLE_DISPATCH_VERDICT="error"
            _CYCLE_DISPATCH_VERDICT_RAW="error"
            _CYCLE_DISPATCH_STATUS="failed"
            _CYCLE_DISPATCH_REASON="router_out_of_turns"
            return 1 ;;
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
# #2189: the stub plays the test stage, which reports a test count.
# shellcheck source=../lib/cycle-report-stub.sh
source "$REPO_ROOT/tests/lib/cycle-report-stub.sh"
zb_stub_reports_tests test

# ─── T1: iter1 timeout sets base; iter2 dispatches with override = base + 50% ─
_seed
unset ZBUILD_ROUTER_MAX_TURNS_OVERRIDE
export ZBUILD_ROUTER_MAX_TURNS=25   # #2458: a stated limit of 25 to escalate
load_template "$FIXT/cycle-max-iter.yaml"
# build:timeout,timeout,timeout → iter1 captures base, iter2+ see escalation.
# The mock template has no per-stage max_turns, so base = default 25; the bumped
# value = 25 + 50% = 37 (rounded down). #1208: G2 abandon is REMOVED, so the
# cycle runs to max_iterations and terminates by-severity (tests fail → rc=1,
# outcome failed; rc=8 before #1850) instead of abandoning at iter 2 (the old
# rc=4). G3 escalation on iter 2 is unchanged.
MOCK_PLAN="build:timeout,timeout,timeout;test:fail,fail,fail"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
unset ZBUILD_ROUTER_MAX_TURNS
assert_eq "T1: exhausted with failing tests → rc=1, outcome failed (G2 abandon removed, #1208)" \
    "1 failed" "$rc ${_CYCLE_LAST_OUTCOME:-unset}"

# Find the build:2:... record — iter 2's dispatch must have seen OVERRIDE=37.
build_iter2=""
for rec in "${OBSERVED_OVERRIDES[@]}"; do
    [[ "$rec" == build:2:* ]] && build_iter2="$rec" && break
done
assert_eq "T1: iter1 build dispatched WITHOUT G3 override (base only)" \
    "build:1:unset" "${OBSERVED_OVERRIDES[0]}"
assert_eq "T1: iter2 build dispatched WITH G3 override = base 25 + 50% = 37" \
    "build:2:37" "$build_iter2"

# Event check.
ev_esc="$(grep -c '"type":"cycle.member.max_turns.escalated"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
if [[ "$ev_esc" -ge 1 ]]; then
    assert_pass "T1: cycle.member.max_turns.escalated emitted (count=$ev_esc)"
else
    assert_fail "T1: no cycle.member.max_turns.escalated event"
fi

# ─── T2: cap at 2× base — if base=25 the cap is 50 (we test logic via a
#         deliberate high base via env so cap math is exercised). ────────────
_seed
unset ZBUILD_ROUTER_MAX_TURNS_OVERRIDE
export ZBUILD_ROUTER_MAX_TURNS=100   # base=100 → bumped=150 → capped at 200
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_PLAN="build:timeout,timeout;test:fail,fail"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
unset ZBUILD_ROUTER_MAX_TURNS
# iter2 build dispatch must record OVERRIDE=150 (100 + 50% = 150, well under
# the 200 cap; not testing the cap edge here, testing the formula off a
# non-default base).
build_iter2_t2=""
for rec in "${OBSERVED_OVERRIDES[@]}"; do
    [[ "$rec" == build:2:* ]] && build_iter2_t2="$rec" && break
done
assert_eq "T2: iter2 build OVERRIDE = base 100 + 50% = 150 (cap=200, not hit)" \
    "build:2:150" "$build_iter2_t2"

# ─── T3: timeout then success → base cleared, no escalation on later iter ────
# Drive a 4-iter cycle: build:timeout,pass,timeout,timeout.
# After iter1 timeout: counter=1, base=25.
# After iter2 pass: counter=0, base cleared (no leak).
# Iter3 timeout: counter=1, base=25 re-captured. Iter4 dispatches with
# OVERRIDE=37 — same fresh escalation, NOT compounded.
_seed
unset ZBUILD_ROUTER_MAX_TURNS_OVERRIDE
export ZBUILD_ROUTER_MAX_TURNS=25   # #2458: a stated limit of 25 to escalate
# cycle-max-iter has max_iterations=3 → use that. Plan: t,p,t.
MOCK_PLAN="build:timeout,pass,timeout;test:fail,fail,fail"
load_template "$FIXT/cycle-max-iter.yaml"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
unset ZBUILD_ROUTER_MAX_TURNS
# Find each iter's build override snapshot.
iter1_build="" iter2_build="" iter3_build=""
for rec in "${OBSERVED_OVERRIDES[@]}"; do
    case "$rec" in
        build:1:*) iter1_build="$rec" ;;
        build:2:*) iter2_build="$rec" ;;
        build:3:*) iter3_build="$rec" ;;
    esac
done
assert_eq "T3: iter1 build no override (fresh)" "build:1:unset" "$iter1_build"
assert_eq "T3: iter2 build escalated (base=25 → 37)" "build:2:37" "$iter2_build"
# iter3: prior was a pass → base cleared, no escalation. Fresh dispatch.
assert_eq "T3: iter3 build no override (pass cleared the bump)" \
    "build:3:unset" "$iter3_build"

# ─── T4 (#2458): no turn limit stays no limit after a timeout ─────────────────
_seed
unset ZBUILD_ROUTER_MAX_TURNS_OVERRIDE ZBUILD_ROUTER_MAX_TURNS
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_PLAN="build:timeout,timeout,timeout;test:fail,fail,fail"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
t4_iter2=""
for rec in "${OBSERVED_OVERRIDES[@]}"; do [[ "$rec" == build:2:* ]] && t4_iter2="$rec" && break; done
assert_eq "T4: a stage with no turn limit gets none after a timeout" "build:2:unset" "$t4_iter2"
assert_eq "T4: ...and no escalation is announced" "0" \
    "$(grep -c '"type":"cycle.member.max_turns.escalated"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"

# ─── T5 (#2458): running out of turns does not stop the loop ─────────────────
_seed
unset ZBUILD_ROUTER_MAX_TURNS_OVERRIDE
export ZBUILD_ROUTER_MAX_TURNS=25
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_PLAN="build:turns,turns,turns;test:fail,fail,fail"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
unset ZBUILD_ROUTER_MAX_TURNS
t5_iters=0
for rec in "${OBSERVED_OVERRIDES[@]}"; do [[ "$rec" == build:* ]] && t5_iters=$((t5_iters + 1)); done
assert_eq "T5: a build that runs out of turns does not mark the loop blocked" "3" "$t5_iters"
_lacks_blocked="$(grep -c '"type":"cycle.blocked"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "T5: ...no cycle.blocked" "0" "$_lacks_blocked"
t5_iter2=""
for rec in "${OBSERVED_OVERRIDES[@]}"; do [[ "$rec" == build:2:* ]] && t5_iter2="$rec" && break; done
assert_eq "T5: ...and its next round gets more turns (25 + 50% = 37)" "build:2:37" "$t5_iter2"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
