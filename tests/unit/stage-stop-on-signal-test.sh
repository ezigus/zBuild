#!/usr/bin/env bash
# tests/unit/stage-stop-on-signal-test.sh — a signal stops the running stage,
# not after it (ADR-054 §7).
#
# Bash runs a trap only once the foreground command returns. A stage run in the
# foreground therefore kept a SIGTERM to the engine waiting until the stage
# chose to end — up to its time limit, 15 minutes by default.
#
# S1 [change] the cycle's TERM trap stops the member running now: the shell
#             returns at once and the member's process is gone
# S2 [guard]  a shell that only catches a signal (a repeat TERM during
#             teardown) keeps waiting: the stage finishes and its rc stands
# S3 [guard]  plugin_stop_running with no stage running is a no-op
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

print_test_header "a signal stops the running stage (ADR-054 §7)"
setup_test_env "stage-stop-on-signal"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
jq -n '{schema_version:1, stage_statuses:{}}' > "$STATE_FILE"

# A stage that names itself, holds for $SLOW_SECS, then exits $SLOW_RC.
mock_plugin_factory "slow" tool 0 >/dev/null
PLUGIN_DIR="$TEST_TEMP_DIR/plugins/tool/slow"
cat > "$PLUGIN_DIR/plugin.sh" <<'EOF'
slow_run() {
    printf '%s\n' "$BASHPID" > "$SLOW_PID_FILE"
    sleep "$SLOW_SECS"
    : > "$SLOW_DONE_FILE"
    return "$SLOW_RC"
}
EOF
export SLOW_PID_FILE="$TEST_TEMP_DIR/slow.pid" SLOW_DONE_FILE="$TEST_TEMP_DIR/slow.done"

# _drive <trap-setup> — run the stage in a shell with that trap, TERM the shell
# once the stage is running, and leave rc/elapsed in $TEST_TEMP_DIR/out.
_drive() {
    rm -f "$SLOW_PID_FILE" "$SLOW_DONE_FILE" "$TEST_TEMP_DIR/out"
    (
        eval "$1"
        _rc=0; plugin_hook_call "$PLUGIN_DIR" run slow "$STATE_FILE" >/dev/null 2>&1 || _rc=$?
        printf '%s\n' "$_rc" > "$TEST_TEMP_DIR/out"
    ) &
    local sh=$! t0
    for _ in $(seq 1 100); do [[ -s "$SLOW_PID_FILE" ]] && break; sleep 0.05; done
    t0=$EPOCHSECONDS
    kill -TERM "$sh" 2>/dev/null || true
    wait "$sh" 2>/dev/null || true
    ELAPSED=$(( EPOCHSECONDS - t0 ))
    STAGE_PID="$(cat "$SLOW_PID_FILE" 2>/dev/null || true)"
}

print_test_section "S1: the cycle's trap stops the member running now"
export SLOW_SECS=30 SLOW_RC=0
_drive '_CYCLE_TRAP_CYCLE_ID=s1; _CYCLE_TRAP_ITER=1; _cycle_install_traps'
if [[ "$ELAPSED" -lt 10 ]]; then
    assert_pass "[S1] the shell returns without waiting for the member (${ELAPSED}s)"
else
    assert_fail "[S1] the shell returns without waiting for the member" "took ${ELAPSED}s; the member holds 30s"
fi
if [[ -n "$STAGE_PID" ]] && kill -0 "$STAGE_PID" 2>/dev/null; then
    assert_fail "[S1] the member does not outlive the stop" "pid $STAGE_PID still alive"
    kill -KILL "$STAGE_PID" 2>/dev/null || true
else
    assert_pass "[S1] the member does not outlive the stop"
fi
assert_file_not_exists "[S1] the member did not run to its end" "$SLOW_DONE_FILE"

print_test_section "S2: a signal that is only caught does not stop the stage"
export SLOW_SECS=1 SLOW_RC=7
_drive "trap ':' INT TERM"
assert_file_exists "[S2] the stage ran to its end" "$SLOW_DONE_FILE"
assert_eq "[S2] …and its rc is what plugin_hook_call returns" "7" "$(cat "$TEST_TEMP_DIR/out" 2>/dev/null)"

print_test_section "S3: nothing running"
_ZB_LC_STAGE_PID=""
plugin_stop_running; _s3=$?
assert_eq "[S3] plugin_stop_running with no stage is a no-op" "0" "$_s3"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
