#!/usr/bin/env bash
# Tests: ADR-029 G2/G3 cross-iteration timeout counter persistence (#844)
#
# When an inner cycle (e.g. build_test_cycle) is re-invoked by an outer cycle's
# next iteration, the consecutive-timeout counter (_CYCLE_TIMEOUT_RUN) and G3
# max_turns base (_CYCLE_TURNS_BASE) must survive the cycle_orchestrator_run
# entry boundary. Without persistence, G2 resets to zero on every re-entry and
# can never fire across outer-cycle iteration boundaries.
#
# T1 [SPEC-1]: two timeouts in first invocation accumulate counter=2 (G2 fires).
#   Second invocation restores counter=2; first timeout → counter=3 → G2 fires
#   immediately (on iter 1 of the second invocation, not iter 2).
# T2 [SPEC-2]: one timeout in first invocation (counter=1, no G2, max_iter=1 exits).
#   Second invocation restores counter=1; first timeout → counter=2 → G2 fires
#   immediately (on iter 1 of the second invocation, not iter 2).
# T3 [SPEC-3] guard: non-timeout pass resets the counter to 0 even within
#   restored state — G2 does not fire after restore+pass+single_timeout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle G2 — cross-iteration timeout counter persistence (ADR-029 #844)"
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

# Mock dispatch driven by a per-stage csv verdict plan (iter-indexed).
# Verdicts: pass | fail | timeout (verdict=error reason=router_timeout)
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

# ─── T1 [SPEC-1]: counter carries across outer-cycle iterations ───────────────
# First invocation: 2 consecutive timeouts → G2 fires (counter=2 in persist).
# Second invocation: counter restored to 2, first timeout → G2 fires at iter 1.

_seed
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_PLAN="build:timeout,timeout,timeout;test:fail,fail,fail"
# Simulate nested call: outer cycle has set _CYCLE_TRAP_CYCLE_ID to its own id.
_CYCLE_TRAP_CYCLE_ID="outer-cycle"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc1=$?; set -e
assert_eq "T1: first invocation fires G2 at iter 2 (rc=4)" "4" "$rc1"
assert_eq "T1: first invocation reason=timeout_abandoned" \
    "timeout_abandoned" "$_CYCLE_LAST_TERMINATED_REASON"

# Second invocation: outer cycle advances outer-iter, re-dispatches inner cycle.
_seed
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_PLAN="build:timeout,timeout,timeout;test:fail,fail,fail"
# Restore outer cycle context (mirrors _cycle_iter_dispatch restoring _CYCLE_TRAP_CYCLE_ID).
_CYCLE_TRAP_CYCLE_ID="outer-cycle"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc2=$?; set -e
assert_eq "[SPEC-1] second invocation fires G2 on first timeout (rc=4)" "4" "$rc2"
assert_eq "[SPEC-1] second invocation reason=timeout_abandoned" \
    "timeout_abandoned" "$_CYCLE_LAST_TERMINATED_REASON"
# G2 must fire at iter 1 of the second invocation: counter was restored to 2,
# so the first timeout increments to 3 ≥ 2 and G2 fires before _cycle_state_write_iter_atomic.
# At baseline (no persistence), counter starts at 0 and G2 fires at iter 2 → 1 entry.
# With persistence, G2 fires at iter 1 → 0 entries recorded.
n_iter2="$(jq -r '.cycle_iterations["build-test"].iter | length' "$STATE_FILE")"
assert_eq "[SPEC-1] G2 fires before any iter is recorded (iter_count=0)" "0" "$n_iter2"

# ─── T2 [SPEC-2]: partial counter (=1) carries and completes G2 ───────────────
# First invocation: 1 timeout (counter=1, no G2), then max_iterations=1 exits.
# Second invocation: counter restored to 1; next timeout fires G2 (counter→2).

# Reset persist maps to isolate T2 from T1's accumulated state.
_CYCLE_TIMEOUT_RUN_PERSIST=()
_CYCLE_TURNS_BASE_PERSIST=()

_seed
load_template "$FIXT/cycle-max-iter.yaml"
# Override max_iterations to 1 so the cycle exits after one iter (one timeout, no G2).
_TPL_CYCLE_MAX_build_test=1
MOCK_PLAN="build:timeout;test:fail"
_CYCLE_TRAP_CYCLE_ID="outer-cycle"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc_t2a=$?; set -e
assert_eq "T2: first invocation exits via max_iterations, not G2 (rc=1)" "1" "$rc_t2a"

# Second invocation: restore counter=1 from persist; first timeout fires G2.
_seed
load_template "$FIXT/cycle-max-iter.yaml"
MOCK_PLAN="build:timeout,timeout,timeout;test:fail,fail,fail"
_CYCLE_TRAP_CYCLE_ID="outer-cycle"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc_t2b=$?; set -e
assert_eq "[SPEC-2] second invocation fires G2 on first timeout (rc=4)" "4" "$rc_t2b"
assert_eq "[SPEC-2] second invocation reason=timeout_abandoned" \
    "timeout_abandoned" "$_CYCLE_LAST_TERMINATED_REASON"
# At baseline: counter starts at 0, G2 fires at iter 2 → 1 entry recorded.
# With persistence: counter restored to 1, first timeout → 2 → G2 fires at iter 1 → 0 entries.
n_iter_t2b="$(jq -r '.cycle_iterations["build-test"].iter | length' "$STATE_FILE")"
assert_eq "[SPEC-2] G2 fires before any iter is recorded (iter_count=0)" "0" "$n_iter_t2b"

# ─── T3 [SPEC-3] guard: non-timeout pass resets counter within restored state ─
# First invocation (top-level, _CYCLE_TRAP_CYCLE_ID=""): clears any stale persist
# state for build-test, then 1 timeout accumulates counter=1 in persist.
# Second invocation (nested): restores counter=1, iter1=pass resets it to 0,
# iter2=timeout sets counter=1 (no G2 since <2), exits via max_iterations.
# G2 must NOT fire — reset semantics are preserved within the restored state.

_seed
load_template "$FIXT/cycle-max-iter.yaml"
_TPL_CYCLE_MAX_build_test=1
MOCK_PLAN="build:timeout;test:fail"
# Top-level (no outer cycle): persist maps cleared for build-test at entry.
_CYCLE_TRAP_CYCLE_ID=""
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; _=$?; set -e

# Second invocation (nested): restore counter=1, pass resets it, single timeout=no G2.
_seed
load_template "$FIXT/cycle-max-iter.yaml"
_TPL_CYCLE_MAX_build_test=2
MOCK_PLAN="build:pass,timeout;test:fail,fail"
_CYCLE_TRAP_CYCLE_ID="outer-cycle"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc_t3=$?; set -e
assert_eq "[SPEC-3] guard: pass resets restored counter; G2 does not fire (rc=1, not 4)" \
    "1" "$rc_t3"

print_test_results
exit $((FAIL > 0))
