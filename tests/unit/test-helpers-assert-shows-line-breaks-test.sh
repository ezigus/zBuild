#!/usr/bin/env bash
# tests/unit/test-helpers-assert-shows-line-breaks-test.sh — a failing assert_eq
# shows a value's line breaks, on one line (#2454, ADR-007).
#
# Why: on #1805 (run 41452299475) six assertions compared "0" with "0⏎0". The
# message printed the second 0 on a line of its own, and the test stage keeps
# only the first line after a ✗ — so every stage was shown
# "expected: 0, got: 0", which reads as impossible rather than as a broken test.
#
# L1 [change] a value with a line break is shown quoted, its breaks as ⏎, on
#             the one detail line
# L2 [guard]  a value with no line break prints as before
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "a failing assert_eq shows line breaks (#2454)"
setup_test_env "assert-shows-line-breaks"

# _child <expected> <actual> — what a failing assert_eq prints, colours removed.
_child() {
    bash -c '
        source "$1/scripts/lib/helpers.sh"
        source "$1/scripts/lib/test-helpers.sh"
        assert_eq "a check" "$2" "$3"
    ' _ "$REPO_ROOT" "$1" "$2" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g'
}

print_test_section "L1: a value with a line break"
_out="$(_child 0 $'0\n0')"
_detail="$(grep -A1 '✗ a check' <<< "$_out" | tail -1)"
assert_contains "[L1] the detail line shows the whole value" "$_detail" 'got: "0⏎0"'
assert_eq "[L1] the value takes no second line" "0" "$(grep -cx '0' <<< "$_out" || true)"
_out2="$(_child $'a\nb' ab)"
assert_contains "[L1] ...the expected value too" "$(grep -A1 '✗ a check' <<< "$_out2" | tail -1)" 'expected: "a⏎b"'

print_test_section "L2: a value with no line break"
_out3="$(_child 1 2)"
assert_contains "[L2] printed as before" "$(grep -A1 '✗ a check' <<< "$_out3" | tail -1)" "expected: 1, got: 2"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
