#!/usr/bin/env bash
# Tests: ADR-029 G2/G3 cross-iteration timeout counter PERSISTENCE (#844),
# re-scoped for #1208 (G2 abandon removed).
#
# The consecutive-timeout counter (_CYCLE_TIMEOUT_RUN) + G3 max_turns base
# (_CYCLE_TURNS_BASE) still survive the cycle_orchestrator_run re-entry boundary
# so G3 escalation carries across outer-cycle iterations. What CHANGED in #1208:
# the counter no longer feeds a fatal abandon — a repeated router timeout is
# NEVER fatal. So this test asserts (a) the counter persists across re-entry
# (observable via the cycle.member.timeout `consecutive` field), and (b) no
# amount of cross-iteration timeout abandons the cycle (rc never 4, no
# cycle.member.timeout_abandoned).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle G2/G3 — cross-iteration timeout counter persistence, no abandon (#844/#1208)"
setup_test_env "cycle-g2-cross-iter-timeout"

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

# Persistence is observable directly on the module-level persist map (same shell).
_persist_build() { printf '%s' "${_CYCLE_TIMEOUT_RUN_PERSIST[build-test:build]:-0}"; }

# ─── T1: counter persists across nested re-entry; never abandons ─────────────
# First invocation (nested under outer-cycle): 1 timeout on the single iter
# (max_iter overridden to 1) accumulates counter=1 in persist.
_CYCLE_TIMEOUT_RUN_PERSIST=(); _CYCLE_TURNS_BASE_PERSIST=()
_seed
load_template "$FIXT/cycle-max-iter.yaml"
_TPL_CYCLE_MAX_build_test=1
MOCK_PLAN="build:timeout;test:fail"
_CYCLE_TRAP_CYCLE_ID="outer-cycle"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc1=$?; set -e
assert_contains "T1: single-iter timeout is non-fatal (rc 2 or 8 by-severity, never 4)" \
    "2 8" "$rc1"
_p1="$(_persist_build)"
assert_eq "[persist] inv1 accumulated timeout counter=1 in persist map" "1" "$_p1"

# Second invocation (same nested outer-cycle): counter restored to 1; the first
# timeout increments to 2 — proving persistence — but does NOT abandon.
_seed
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_PLAN="build:timeout,timeout,timeout;test:fail,fail,fail"
_CYCLE_TRAP_CYCLE_ID="outer-cycle"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc2=$?; set -e
_p2="$(_persist_build)"; [[ "$_p2" =~ ^[0-9]+$ ]] || _p2=0
[[ "$_p2" -ge 2 ]] \
    && assert_pass "[persist] restored counter carried across re-entry (persist grew to $_p2 ≥ 2)" \
    || assert_fail "[persist] counter did not persist across re-entry" "persist=$_p2"
assert_eq "[no-abandon] second invocation does NOT abandon on timeout (rc=8 by-severity, not 4)" \
    "8" "$rc2"
if [[ "$_CYCLE_LAST_TERMINATED_REASON" == "timeout_abandoned" ]]; then
    assert_fail "[no-abandon] reason is not timeout_abandoned" "$_CYCLE_LAST_TERMINATED_REASON"
else
    assert_pass "[no-abandon] reason is not timeout_abandoned (got $_CYCLE_LAST_TERMINATED_REASON)"
fi
ev_ab="$(grep -c '"type":"cycle.member.timeout_abandoned"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
assert_eq "[no-abandon] no cycle.member.timeout_abandoned event ever (G2 abandon removed)" "0" "$ev_ab"

# ─── T2: a non-timeout dispatch resets the restored counter ──────────────────
_CYCLE_TIMEOUT_RUN_PERSIST=(); _CYCLE_TURNS_BASE_PERSIST=()
_seed
load_template "$FIXT/cycle-max-iter.yaml"
_TPL_CYCLE_MAX_build_test=1
MOCK_PLAN="build:timeout;test:fail"
_CYCLE_TRAP_CYCLE_ID="outer-cycle"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; _=$?; set -e

_seed
load_template "$FIXT/cycle-max-iter.yaml"
_TPL_CYCLE_MAX_build_test=2
MOCK_PLAN="build:pass,timeout;test:fail,fail"
_CYCLE_TRAP_CYCLE_ID="outer-cycle"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc3=$?; set -e
# pass resets the restored counter, then one timeout → count=1 only.
_p3="$(_persist_build)"; [[ "$_p3" =~ ^[0-9]+$ ]] || _p3=0
[[ "$_p3" -le 1 ]] \
    && assert_pass "[reset] non-timeout dispatch reset the restored counter (persist ≤ 1, got $_p3)" \
    || assert_fail "[reset] counter should reset on pass" "persist=$_p3"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
