#!/usr/bin/env bash
# Integration: cycle-orchestrator honors SIGINT propagation
# (ADR-025 / Wave 15-B #684).
#
# Wave 15 dogfood `20260604061056-1003` discovered that
# _cycle_iter_dispatch swallowed a stage's SIGINT and treated it as a
# generic fail (fail++), so the cycle kept iterating after Ctrl-C. This
# test asserts:
#   T1. a stage that records the abort word sigint and returns 1 makes
#       cycle_orchestrator_run return 1 immediately with outcome aborted —
#       no further stages or iterations are dispatched.
#   T2. The cycle terminated_reason is "aborted".
#   T3. A sentinel file written between iterations (simulating a sibling
#       subshell catching SIGINT) makes the outer iter loop bail at the
#       next iter boundary — pre-flight check works.
#   T4. _cycle_on_signal records the word (sigterm) and does not return 130.
#
# #1850 (ADR-054 §4, ADR-025): no rc carries the abort any more — it was 130.
# An abort is a recorded WORD (_zbuild_abort_reason); an empty sentinel file
# reads as sigint. Every loop end is rc 0/1 plus _CYCLE_LAST_OUTCOME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator SIGINT propagation (ADR-025 / #684)"
setup_test_env "cycle-orch-sigint"

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
    rm -f "$ZBUILD_STATE_DIR/.abort.signal"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
    # Reset call counters.
    DISPATCH_CALLS=0
    : > "$TEST_TEMP_DIR/dispatch-trace"
}

# ─── T1: a stage's recorded SIGINT halts the cycle immediately ────────────

print_test_section "T1: a stage that records sigint halts the cycle: rc=1, outcome aborted"

_seed_state

# Mock dispatch hook — first call records the abort word sigint and returns 1
# (what a stage killed by Ctrl-C reports since #1850; it used to return 130).
# Any subsequent call would indicate the cycle kept iterating after
# the abort signal — that is the dogfood bug, which must NOT happen.
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    DISPATCH_CALLS=$((DISPATCH_CALLS + 1))
    printf '%s|%s|%s\n' "$DISPATCH_CALLS" "$stage" "$iter" >> "$TEST_TEMP_DIR/dispatch-trace"
    _CYCLE_DISPATCH_VERDICT="fail"
    _CYCLE_DISPATCH_STATUS="failed"
    # First call: pretend the child died from SIGINT.
    if [[ $DISPATCH_CALLS -eq 1 ]]; then
        _zbuild_abort sigint
        return 1
    fi
    # Any further calls would be a bug — return 0 to make the assertion clearer.
    return 0
}

load_template "$FIXT/cycle-converges-iter2.yaml"

set +e
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
rc=$?
set -e

assert_eq "T1: cycle_orchestrator_run rc=1, outcome aborted" "1 aborted" "$rc ${_CYCLE_LAST_OUTCOME:-unset}"
assert_eq "T1: the recorded abort word is sigint" "sigint" "$(_zbuild_abort_reason)"
assert_eq "T1: dispatch called exactly once (no further iterations)" "1" "$DISPATCH_CALLS"
assert_eq "T1: terminated_reason=aborted" "aborted" "$_CYCLE_LAST_TERMINATED_REASON"
# The word lives in-process as well as in the sentinel; clear both for T2.
_zbuild_disarm_abort_sentinel

# ─── T2: sentinel file written between iters halts at next iter boundary ──

print_test_section "T2: sentinel pre-flight halts cycle at next iter boundary"

_seed_state

# Mock dispatch hook — first iter (2 stages) passes; arm the sentinel after
# iter 1's last stage. The outer iter loop's pre-flight should observe the
# sentinel before starting iter 2 and bail (rc=1, outcome aborted).
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    DISPATCH_CALLS=$((DISPATCH_CALLS + 1))
    printf '%s|%s|%s\n' "$DISPATCH_CALLS" "$stage" "$iter" >> "$TEST_TEMP_DIR/dispatch-trace"
    _CYCLE_DISPATCH_VERDICT="fail"
    _CYCLE_DISPATCH_STATUS="failed"
    # After iter 1's "test" stage (call 2), arm the sentinel — simulating a
    # sibling subshell catching SIGINT while we were running.
    if [[ "$stage" == "test" && "$iter" == "1" ]]; then
        : > "$ZBUILD_STATE_DIR/.abort.signal"
    fi
    # Always succeed so the cycle would naturally continue if pre-flight
    # didn't trip.
    return 0
}

load_template "$FIXT/cycle-converges-iter2.yaml"
set +e
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
rc=$?
set -e

assert_eq "T2: cycle_orchestrator_run rc=1, outcome aborted (sentinel pre-flight)" \
    "1 aborted" "$rc ${_CYCLE_LAST_OUTCOME:-unset}"
assert_eq "T2: an empty sentinel reads as the abort word sigint" "sigint" "$(_zbuild_abort_reason)"
# 2 dispatches in iter 1; iter 2 must not start ⇒ exactly 2 calls.
assert_eq "T2: dispatch called exactly twice (iter 2 never starts)" "2" "$DISPATCH_CALLS"
assert_eq "T2: terminated_reason=aborted" "aborted" "$_CYCLE_LAST_TERMINATED_REASON"

# Clean up the sentinel (and the in-process word) so neither leaks into T3.
rm -f "$ZBUILD_STATE_DIR/.abort.signal"
_zbuild_disarm_abort_sentinel

# ─── T3: sentinel written between stages within one iter halts mid-iter ───

print_test_section "T3: sentinel pre-flight halts dispatch within an iter"

_seed_state

# Mock: first stage (build) arms the sentinel; the pre-flight in
# _cycle_iter_dispatch's stage loop must fire before the next stage (test).
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    DISPATCH_CALLS=$((DISPATCH_CALLS + 1))
    printf '%s|%s|%s\n' "$DISPATCH_CALLS" "$stage" "$iter" >> "$TEST_TEMP_DIR/dispatch-trace"
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    # Build (first stage of iter 1) arms the sentinel — simulates the child
    # itself receiving SIGINT mid-build and writing the sentinel before it
    # returned (or a sibling subshell beating us to it).
    if [[ "$stage" == "build" && "$iter" == "1" ]]; then
        : > "$ZBUILD_STATE_DIR/.abort.signal"
    fi
    return 0
}

load_template "$FIXT/cycle-converges-iter2.yaml"
set +e
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
rc=$?
set -e

assert_eq "T3: cycle_orchestrator_run rc=1, outcome aborted" "1 aborted" "$rc ${_CYCLE_LAST_OUTCOME:-unset}"
# build ran once; test must NOT run.
assert_eq "T3: dispatch called exactly once (test never starts)" "1" "$DISPATCH_CALLS"

rm -f "$ZBUILD_STATE_DIR/.abort.signal"
_zbuild_disarm_abort_sentinel

# ─── T4: the cycle's own signal handler records the word ─────────────────
# #1850: _cycle_on_signal used to `return 130`; the number was the only record
# that a signal had arrived. Now it records sigint/sigterm (ADR-025) so the
# next dispatch boundary sees it, and returns no signal code. Run in a subshell
# so the handler's trap clearing cannot touch this file's shell.

print_test_section "T4: _cycle_on_signal SIGTERM records sigterm, returns no 130"

_seed_state
t4_out="$(
    _CYCLE_TRAP_CYCLE_ID="build-test"; _CYCLE_TRAP_ITER=1
    _t4_rc=0
    _cycle_on_signal SIGTERM || _t4_rc=$?
    printf '%s %s' "$_t4_rc" "$(_zbuild_abort_reason)"
)"
t4_rc="${t4_out%% *}"
assert_eq "T4: _cycle_on_signal SIGTERM records the word sigterm" "sigterm" "${t4_out#* }"
if [[ "$t4_rc" == "130" || "$t4_rc" == "143" ]]; then
    assert_fail "T4: _cycle_on_signal returns no signal rc" "returned $t4_rc"
else
    assert_pass "T4: _cycle_on_signal returns no signal rc (rc=$t4_rc)"
fi
rm -f "$ZBUILD_STATE_DIR/.abort.signal"

# ─── SPEC-3: cycle handler takes the INT slot from the runner handler ─────────
# GUARD: _cycle_install_traps must override any prior INT/TERM handler so that
# a signal during a cycle fires the cycle handler (not the runner's). This
# confirms the nested-handler ownership contract that makes _runner_rearm_traps
# necessary and safe: cycle takes the slot on entry, clears it on exit, then
# the runner re-arms. Verified by trap -p inspection and direct handler call.

print_test_section "SPEC-3 (guard): cycle handler overrides runner handler during cycle (TERM)"

_runner_marker="$TEST_TEMP_DIR/spec3-runner-marker"
_cycle_marker="$TEST_TEMP_DIR/spec3-cycle-marker"
rm -f "$_runner_marker" "$_cycle_marker"

# HERMETICITY (#1713 family): this uses TERM, not INT, on purpose.
# `scripts/run-tests.sh` runs test files as BACKGROUND jobs, and POSIX says a
# background job in a non-interactive shell inherits SIGINT and SIGQUIT as
# IGNORED — bash then refuses to install a handler, so `trap ... INT` is a
# silent no-op. Measured, background child:
#   INT  -> trap -- ''          SIGINT     (cannot be trapped)
#   QUIT -> trap -- ''          SIGQUIT    (cannot be trapped)
#   TERM -> trap -- 'h TERM' SIGTERM       (trappable)
#   USR1 -> trap -- 'h USR1' SIGUSR1       (trappable)
# The first cut asserted INT and so passed standalone and failed in the suite.
# TERM is trappable in both contexts AND is one of the two signals the runner
# actually handles, so the guard exercises the real path either way.
spec3_result=$(
    (
        _RUNNER_M="$TEST_TEMP_DIR/spec3-runner-marker"
        _CYCLE_M="$TEST_TEMP_DIR/spec3-cycle-marker"

        # Simulate the runner's handler (installed by the runner on startup).
        # Both sims exit 1, as the real handlers do since #1850 (it was 143).
        _runner_signal_trap() { touch "$_RUNNER_M"; exit 1; }
        trap '_runner_signal_trap TERM' TERM

        # Simulate cycle installing its own handler (_cycle_install_traps).
        _cycle_on_signal_sim() { touch "$_CYCLE_M"; exit 1; }
        trap '_cycle_on_signal_sim TERM' TERM

        # The cycle handler must now own the slot, not the runner's.
        term_handler=$(trap -p TERM 2>/dev/null || true)
        if ! grep -q "_cycle_on_signal_sim" <<< "$term_handler"; then
            echo "cycle_handler_not_installed"
            exit 1
        fi
        if grep -q "_runner_signal_trap" <<< "$term_handler"; then
            echo "runner_handler_still_active"
            exit 1
        fi

        # Report BEFORE invoking: the sim handler exits, so anything echoed
        # after it never runs and the diagnostic is permanently empty. That dead
        # variable shipped in the first cut and was caught in review.
        echo "cycle_handler_owned_slot"

        # Invoke the cycle handler directly (simulating SIGTERM during a cycle).
        # `kill -TERM $$` inside a bash subshell targets the PARENT shell ($$
        # does not change in subshells), so direct invocation is used instead.
        _cycle_on_signal_sim 2>/dev/null || true
    ) 2>/dev/null || true
)

# Cycle marker must exist; runner marker must NOT exist.
if [[ -f "$_cycle_marker" && ! -f "$_runner_marker" ]]; then
    assert_pass "[SPEC-3] cycle TERM handler fires; runner handler does not (nested override works)"
elif [[ -f "$_runner_marker" ]]; then
    assert_fail "[SPEC-3] cycle TERM handler fires; runner handler does not" \
        "runner handler fired — nested override did not take effect"
else
    assert_fail "[SPEC-3] cycle TERM handler fires; runner handler does not" \
        "cycle handler did not fire (spec3_result=$spec3_result)"
fi

rm -f "$_runner_marker" "$_cycle_marker"

print_test_results
exit $((FAIL > 0))
