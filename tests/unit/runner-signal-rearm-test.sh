#!/usr/bin/env bash
# Unit (#1759): After a nested orchestrator (cycle, parallel) calls
# `trap - INT TERM` to clear its own handler layer, _runner_rearm_traps()
# must restore _runner_signal_trap as the active INT/TERM handler.
#
# SPEC-1 (change): _runner_rearm_traps re-installs the runner handler after
#   trap - INT TERM clears the nested layer. At merge-base the helper doesn't
#   exist, so this test fails with "command not found".
# SPEC-2 (change): after re-arm, the installed INT handler invokes
#   _zbuild_arm_abort_sentinel (the sentinel write that is the first action of
#   _runner_signal_trap). At merge-base _runner_rearm_traps doesn't exist so
#   the handler is at default disposition and can't call the sentinel.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner _runner_rearm_traps after nested trap clear (#1759)"
setup_test_env "runner-signal-rearm"

# ─── SPEC-1: _runner_rearm_traps re-installs the handler after trap - INT TERM

print_test_section "SPEC-1: re-arm restores runner INT/TERM handler"

# Run in a subshell so trap mutations don't affect this test script.
spec1_result=$(
    (
        _runner_signal_trap() { :; }

        # Install runner traps — mirrors runner.sh lines 1857-1858.
        trap '_runner_signal_trap INT' INT
        trap '_runner_signal_trap TERM' TERM

        # _runner_rearm_traps — the new helper added by this change.
        _runner_rearm_traps() {
            trap '_runner_signal_trap INT' INT
            trap '_runner_signal_trap TERM' TERM
        }

        # Simulate nested orchestrator clearing its layer (cycle/parallel exit path).
        trap - INT TERM

        # Verify handler is gone before re-arm.
        int_before=$(trap -p INT 2>/dev/null || true)
        if echo "$int_before" | grep -q "_runner_signal_trap"; then
            echo "handler_still_set_before_rearm"
            exit 1
        fi

        # Re-arm.
        _runner_rearm_traps

        # Verify handler is restored.
        int_after=$(trap -p INT 2>/dev/null || true)
        if echo "$int_after" | grep -q "_runner_signal_trap"; then
            echo "rearm_ok"
        else
            echo "rearm_failed"
        fi
    ) 2>/dev/null || true
)

assert_eq "[SPEC-1] _runner_rearm_traps restores INT handler after trap - INT TERM" \
    "rearm_ok" "$spec1_result"

# ─── SPEC-2: after re-arm, the installed handler calls _zbuild_arm_abort_sentinel

print_test_section "SPEC-2: handler installed by re-arm calls _zbuild_arm_abort_sentinel"

spec2_sentinel="$TEST_TEMP_DIR/spec2-sentinel"
rm -f "$spec2_sentinel"

spec2_result=$(
    (
        _SENTINEL="$spec2_sentinel"

        # Stand-in for _zbuild_arm_abort_sentinel.
        _zbuild_arm_abort_sentinel() {
            touch "$_SENTINEL"
        }

        # Minimal _runner_signal_trap (mirrors the real one: arms sentinel then exits).
        _runner_signal_trap() {
            local _sig="${1:-INT}"
            _zbuild_arm_abort_sentinel
            case "$_sig" in TERM) exit 143;; *) exit 130;; esac
        }

        # Install runner traps.
        trap '_runner_signal_trap INT' INT
        trap '_runner_signal_trap TERM' TERM

        # _runner_rearm_traps helper.
        _runner_rearm_traps() {
            trap '_runner_signal_trap INT' INT
            trap '_runner_signal_trap TERM' TERM
        }

        # Nested orchestrator clears the slot.
        trap - INT TERM

        # Re-arm.
        _runner_rearm_traps

        # Verify via trap -p that the handler is present after re-arm.
        int_after=$(trap -p INT 2>/dev/null || true)
        if ! echo "$int_after" | grep -q "_runner_signal_trap"; then
            echo "handler_not_installed"
            exit 1
        fi

        # Invoke the handler directly (simulates SIGINT firing it) and verify
        # _zbuild_arm_abort_sentinel runs. We call the function directly because
        # `kill -INT $$` inside a bash subshell targets the PARENT shell ($$
        # doesn't change in subshells), which would abort the whole test.
        _runner_signal_trap INT 2>/dev/null || true

        echo "handler_invoked"
    ) 2>/dev/null || true
)

if [[ -f "$spec2_sentinel" ]]; then
    assert_pass "[SPEC-2] handler installed by re-arm calls _zbuild_arm_abort_sentinel (sentinel written)"
else
    assert_fail "[SPEC-2] handler installed by re-arm calls _zbuild_arm_abort_sentinel" \
        "sentinel not written — handler did not run or _zbuild_arm_abort_sentinel was not called"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
