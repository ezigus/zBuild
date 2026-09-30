#!/usr/bin/env bash
# tests/unit/test-helpers-assert-fail-errexit-test.sh — recording a failure
# never stops the test file (#2234).
#
# Why: assert_fail ended on `[[ -n "$detail" ]] && echo …`, so called WITHOUT a
# detail it returned 1. Under `set -e`, `if …; then assert_pass …; else
# assert_fail "…"; fi` then exits the whole file at its first failure, and every
# assertion after it goes unmeasured. On #1835 that hid 13 SPECs at the
# merge-base — the gate read them as regressed / as valid controls. 92 test
# files use `set -e` with a bare `assert_fail "…"`.
#
# F1 [change] under set -e, a bare assert_fail in an else-branch does not stop
#             the file
# F2 [change] assert_fail returns 0 with and without a detail
# F3 [guard]  it still records the failure (FAIL counts it)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "assert_fail never stops the test file (#2234)"
setup_test_env "assert-fail-errexit"

_child="$(bash -c '
    set -euo pipefail
    source "$1/scripts/lib/helpers.sh"
    source "$1/scripts/lib/test-helpers.sh"
    if false; then assert_pass "x"; else assert_fail "a failure with no detail"; fi
    echo "REACHED-AFTER-BARE"
    assert_fail "a failure with a detail" "the detail"
    echo "REACHED-AFTER-DETAIL"
    printf "FAIL=%s\n" "$FAIL"
' _ "$REPO_ROOT" 2>&1)"
assert_contains "[F1] a bare assert_fail under set -e does not stop the file" "$_child" "REACHED-AFTER-BARE"
assert_contains "[F1] ...nor does one with a detail" "$_child" "REACHED-AFTER-DETAIL"
assert_contains "[F3] both failures are recorded" "$_child" "FAIL=2"

_rc="$(bash -c '
    source "$1/scripts/lib/helpers.sh"
    source "$1/scripts/lib/test-helpers.sh"
    assert_fail "no detail" >/dev/null; a=$?
    assert_fail "with detail" "d" >/dev/null; b=$?
    printf "%s %s" "$a" "$b"
' _ "$REPO_ROOT" 2>/dev/null)"
assert_eq "[F2] assert_fail returns 0 with and without a detail" "0 0" "$_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
