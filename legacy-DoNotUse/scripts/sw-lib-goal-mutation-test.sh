#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  GOAL mutation RETURN trap tests — issue #362                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "GOAL mutation RETURN trap tests (issue #362)"
setup_test_env "sw-lib-goal-mutation-test"
_test_cleanup_hook() { cleanup_test_env; }

# ── Simulate a mutation function with RETURN trap (the fixed pattern) ────────

mutating_function_with_trap() {
    local original_goal="$GOAL"
    trap '{ GOAL="$original_goal"; trap - RETURN; }' RETURN
    GOAL="$GOAL

BLOCKING ISSUES — something to fix"
    return "${1:-0}"
}

mutating_function_without_trap() {
    local original_goal="$GOAL"
    GOAL="$GOAL

BLOCKING ISSUES — something to fix"
    # Manual restore only at normal exit path
    local rc=0
    inner_call() { return "${1:-0}"; }
    if inner_call "${1:-0}"; then
        GOAL="$original_goal"
        return 0
    else
        GOAL="$original_goal"
        return 1
    fi
}

print_test_section "RETURN trap restores GOAL on success"
GOAL="Original goal"
mutating_function_with_trap 0 || true
assert_eq "RETURN trap restores GOAL after success" "Original goal" "$GOAL"

print_test_section "RETURN trap restores GOAL on failure"
GOAL="Original goal"
mutating_function_with_trap 1 || true
assert_eq "RETURN trap restores GOAL after failure" "Original goal" "$GOAL"

print_test_section "RETURN trap restores GOAL even when subshell exits under set -e"
GOAL="Original goal"
# Verify the trap fires even when the function is called in a conditional
if mutating_function_with_trap 0; then
    :
fi
assert_eq "RETURN trap fires when function called in if-branch" "Original goal" "$GOAL"

print_test_section "Without trap: GOAL restored on normal exit"
GOAL="Original goal"
mutating_function_without_trap 0 || true
assert_eq "Manual restore works on success path" "Original goal" "$GOAL"

print_test_section "Without trap: GOAL restored on failure exit"
GOAL="Original goal"
mutating_function_without_trap 1 || true
assert_eq "Manual restore works on failure path" "Original goal" "$GOAL"

print_test_results
