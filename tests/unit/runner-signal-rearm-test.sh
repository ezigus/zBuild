#!/usr/bin/env bash
# Unit (#1759): After a nested orchestrator (cycle, parallel) calls
# `trap - INT TERM` to clear its own handler layer, _runner_rearm_traps()
# must restore _runner_signal_trap as the active INT/TERM handler.
#
# SPEC-1 (change): _runner_rearm_traps is defined as a top-level function in
#   runner.sh. At merge-base the helper does not exist at top level, so
#   `declare -f _runner_rearm_traps` returns non-zero and this test fails.
# SPEC-2 (change): after re-arm, the installed INT handler invokes
#   _zbuild_arm_abort_sentinel (the sentinel write that is the first action of
#   _runner_signal_trap). At merge-base _runner_rearm_traps doesn't exist so
#   the handler is at default disposition and the sentinel is never written.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner _runner_rearm_traps after nested trap clear (#1759)"
setup_test_env "runner-signal-rearm"

# Source runner.sh so _runner_rearm_traps is available if it is a top-level
# function (which this change makes it). At merge-base the function is absent.
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/runner.sh"

# ─── SPEC-1: _runner_rearm_traps exists as a top-level function ──────────────

print_test_section "SPEC-1: _runner_rearm_traps is defined in runner.sh (top-level)"

assert_eq "[SPEC-1] _runner_rearm_traps is defined as a top-level function in runner.sh" \
    "ok" \
    "$(declare -f _runner_rearm_traps >/dev/null 2>&1 && echo ok || echo missing)"

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

        # Install runner traps — mirrors runner.sh initial trap install.
        trap '_runner_signal_trap INT' INT
        trap '_runner_signal_trap TERM' TERM

        # Nested orchestrator clears the slot (simulates cycle/parallel exit path).
        trap - INT TERM

        # Re-arm using the function sourced from runner.sh.
        # At merge-base this call fails with "command not found" because
        # _runner_rearm_traps is inside main() and not accessible after source.
        _runner_rearm_traps

        # Verify via trap -p that the handler is present after re-arm.
        int_after=$(trap -p INT 2>/dev/null || true)
        if ! echo "$int_after" | grep -q "_runner_signal_trap"; then
            echo "handler_not_installed"
            exit 1
        fi

        # Invoke the handler directly (simulating SIGINT firing it) and verify
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
