#!/usr/bin/env bash
# tests/unit/test-wait-for-exit-test.sh — a test that signals a process waits for
# it with a limit (wait_for_exit, tests/lib/test-helpers.sh; #2639, ADR-012).
#
# run-tests-killed-tier-test.sh [SPEC-3] sent SIGTERM to the test runner and
# then waited for it with no limit. A runner that ignores the signal — the bug
# that test exists to catch — hung the test until CI killed the job (Coverage
# on #2633, over 480 s), with nothing saying why.
#
# [#2639/SPEC-3] a process that ends on its own: its exit status comes back
# [#2639/SPEC-3] a process that ends on the signal: 128 + the signal comes back
# [#2639/SPEC-3] a process that ignores the signal: 124 within the limit, and
#                it and everything under it are gone
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "wait_for_exit: a signalled process is waited for with a limit"
setup_test_env "test-wait-for-exit"

if ! declare -F wait_for_exit >/dev/null; then
    assert_fail "[#2639/SPEC-3] wait_for_exit exists" "not defined in tests/lib/test-helpers.sh"
    cleanup_test_env; print_test_results; exit 1
fi

# started <marker>: until the fixture has written its marker (10 s at most).
started() { local i; for (( i = 0; i < 200; i++ )); do [[ -e "$1" ]] && return 0; sleep 0.05; done; return 1; }

print_test_section "a process that ends on its own"
bash -c 'exit 7' &
_p=$!
_rc=0; wait_for_exit "$_p" 200 0.05 || _rc=$?
assert_eq "[#2639/SPEC-3] its exit status comes back" "7" "$_rc"

print_test_section "a process that ends on the signal"
_m="$TEST_TEMP_DIR/term.started"
bash -c 'touch "$1"; while :; do sleep 0.2; done' _ "$_m" &
_p=$!
if started "$_m"; then
    kill -TERM "$_p" 2>/dev/null
    _rc=0; wait_for_exit "$_p" 200 0.05 || _rc=$?
    assert_eq "[#2639/SPEC-3] 128 + SIGTERM comes back" "143" "$_rc"
else
    zb_test_kill_tree "$_p"; assert_fail "[#2639/SPEC-3] the fixture started" "no start marker"
fi

print_test_section "a process that ignores the signal, with a child that outlives it"
# The child ignores TERM too and runs until killed, and names itself in a file:
# only killing the whole tree, not just the parent, leaves nothing behind.
_m="$TEST_TEMP_DIR/ignore.started" _cf="$TEST_TEMP_DIR/ignore.child"
bash -c 'trap "" TERM
         bash -c "trap \"\" TERM; echo \$\$ > \"\$1\"; while :; do sleep 0.2; done" _ "$2" &
         while [[ ! -s "$2" ]]; do sleep 0.05; done
         touch "$1"; while :; do sleep 0.2; done' _ "$_m" "$_cf" &
_p=$!
if started "$_m"; then
    _child="$(cat "$_cf")"
    kill -TERM "$_p" 2>/dev/null
    _rc=0; wait_for_exit "$_p" 40 0.05 || _rc=$?
    assert_eq "[#2639/SPEC-3] 124 comes back once the limit passes" "124" "$_rc"
    _gone() { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }
    assert_eq "[#2639/SPEC-3] the process is gone" "gone" "$(_gone "$_p")"
    assert_eq "[#2639/SPEC-3] …and so is its child, which ignored the signal too" "gone" "$(_gone "$_child")"
else
    zb_test_kill_tree "$_p"; assert_fail "[#2639/SPEC-3] the fixture started" "no start marker"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
