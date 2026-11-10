#!/usr/bin/env bash
# tests/unit/tests-signal-only-their-own-test.sh — a test signals only the
# processes it started (ADR-012, #2510).
#
# stage-stop-on-signal-test.sh looked for its watchdog's `sleep 987` across the
# whole machine, then KILLed that sleep's parent and every child of it. With
# suites running side by side it found other suites' sleeps; with the sleep's
# parent gone, the parent was launchd and `pkill -KILL -P 1` reached every
# process of the user whose parent is launchd.
#
# P1 no test passes a pid it read from `ps -o ppid` to kill or pkill
# P2 no test looks across the machine for a fixed `sleep <number>`: the number
#    is made for the run, so another run's sleep never matches
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a test signals only the processes it started (#2510)"

_self="tests/unit/tests-signal-only-their-own-test.sh"
_files="$(cd "$REPO_ROOT" && git ls-files -- 'tests/*.sh' 'plugins/*/tests/*.sh' 'plugins/*/*/tests/*.sh')"

print_test_section "P1: never a parent read from ps"
_p1=""
while IFS= read -r _f; do
    [[ -n "$_f" && "$_f" != "$_self" ]] || continue
    _hit="$(/usr/bin/grep -nE '(pkill|kill)[^#]*\$\(ps -o ppid' "$REPO_ROOT/$_f" || true)"
    [[ -n "$_hit" ]] && _p1+="$_f: ${_hit%%$'\n'*}"$'\n'
done <<< "$_files"
assert_eq "[P1] no test kills a pid it read from ps -o ppid" "" "${_p1%$'\n'}"

print_test_section "P2: never a fixed sleep across the machine"
_p2=""
while IFS= read -r _f; do
    [[ -n "$_f" && "$_f" != "$_self" ]] || continue
    _hit="$(/usr/bin/grep -nE "p(grep|kill)( +-[A-Za-z]+)* +-f +[\"'][^\"']*sleep [0-9]" "$REPO_ROOT/$_f" || true)"
    [[ -n "$_hit" ]] && _p2+="$_f: ${_hit%%$'\n'*}"$'\n'
done <<< "$_files"
assert_eq "[P2] no test searches the machine for a fixed sleep" "" "${_p2%$'\n'}"

print_test_results
