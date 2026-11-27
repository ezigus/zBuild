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
started "$_m"
kill -TERM "$_p" 2>/dev/null
_rc=0; wait_for_exit "$_p" 200 0.05 || _rc=$?
assert_eq "[#2639/SPEC-3] 128 + SIGTERM comes back" "143" "$_rc"

print_test_section "a process that ignores the signal"
_m="$TEST_TEMP_DIR/ignore.started"
bash -c 'trap "" TERM; touch "$1"; while :; do sleep 0.2; done' _ "$_m" &
_p=$!
started "$_m"
_tree="$_p $(pgrep -P "$_p" 2>/dev/null | tr '\n' ' ')"
kill -TERM "$_p" 2>/dev/null
_rc=0; wait_for_exit "$_p" 40 0.05 || _rc=$?
assert_eq "[#2639/SPEC-3] 124 comes back once the limit passes" "124" "$_rc"
_left=0
for _q in $_tree; do kill -0 "$_q" 2>/dev/null && _left=$((_left + 1)); done
assert_eq "[#2639/SPEC-3] it and everything under it are gone" "0" "$_left"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
