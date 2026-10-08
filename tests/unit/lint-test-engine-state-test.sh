#!/usr/bin/env bash
# tests/unit/lint-test-engine-state-test.sh — #1799: a test makes the engine's
# loop state with the engine's own writers, never by hand.
#
# #1799's first attempt read `cycle_iterations.<loop>.iterations_used`; the
# engine writes `current_iter`. Its test passed anyway, because it wrote the
# state file by hand with the field the code expected. A hand-written
# `cycle_iterations` holds whatever its author assumed. The helper
# zb_engine_loop_state (scripts/lib/test-helpers.sh) runs the engine's writers
# instead, and scripts/lib/lint-test-engine-state.sh refuses a hand-written one.
#
# E1 [code] a test writing a `"cycle_iterations":{` JSON literal is refused, by name
# E2 [code] a test building one in jq (`cycle_iterations: {` / `.cycle_iterations =`) is refused
# E3 [code] a test that uses zb_engine_loop_state is clean
# E4 [code] the real tree is clean
# E5 [code] zb_engine_loop_state writes the fields the engine writes
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "lint: tests make engine loop state with the engine's writers (#1799)"
setup_test_env "lint-test-engine-state"

LINT="$REPO_ROOT/scripts/lib/lint-test-engine-state.sh"
assert_file_exists "[setup] the lint exists" "$LINT"

_root() {  # <name> <test file body> → a fake repo root holding one test file
    local r="$TEST_TEMP_DIR/$1"
    mkdir -p "$r/tests/unit"
    printf '%s\n' "$2" > "$r/tests/unit/x-test.sh"
    printf '%s' "$r"
}

R1="$(_root literal 'printf '"'"'{"cycle_iterations":{"b":{"status":"max_iterations","iterations_used":5}}}'"'"' > "$S"')"  # lint-test-engine-state:allow — a seeded offender
_rc=0; _out="$(bash "$LINT" "$R1" 2>&1)" || _rc=$?
assert_eq "[E1] a hand-written cycle_iterations literal is refused" "1" "$_rc"
assert_contains "[E1] ...naming the file" "$_out" "tests/unit/x-test.sh"

R2="$(_root jqbuilt 'jq -n '"'"'{cycle_iterations: {b: {status: "max_iterations"}}}'"'"' > "$S"')"  # lint-test-engine-state:allow — a seeded offender
_rc=0; bash "$LINT" "$R2" >/dev/null 2>&1 || _rc=$?
assert_eq "[E2] one built in jq is refused" "1" "$_rc"
R2b="$(_root jqset 'jq '"'"'.cycle_iterations = {}'"'"' "$S"')"  # lint-test-engine-state:allow — a seeded offender
_rc=0; bash "$LINT" "$R2b" >/dev/null 2>&1 || _rc=$?
assert_eq "[E2] ...and so is an assignment to it" "1" "$_rc"

R3="$(_root helper 'zb_engine_loop_state "$S" build_test_cycle 3 3 max_iterations
jq -r ".cycle_iterations.build_test_cycle.current_iter" "$S"')"
_rc=0; bash "$LINT" "$R3" >/dev/null 2>&1 || _rc=$?
assert_eq "[E3] a test using zb_engine_loop_state (and reading the state) is clean" "0" "$_rc"

_rc=0; _out="$(bash "$LINT" "$REPO_ROOT" 2>&1)" || _rc=$?
assert_eq "[E4] the real tree is clean" "0" "$_rc"
[[ "$_rc" -eq 0 ]] || printf '%s\n' "$_out" >&2

S5="$TEST_TEMP_DIR/state.json"
printf '{"schema_version":1,"status":"running"}\n' > "$S5"
zb_engine_loop_state "$S5" build_test_cycle 2 3 max_iterations
assert_eq "[E5] the helper writes the engine's fields: status, current_iter, max_iterations" \
    "max_iterations 2 3" \
    "$(jq -r '.cycle_iterations.build_test_cycle | "\(.status) \(.current_iter) \(.max_iterations)"' "$S5" 2>/dev/null)"

cleanup_test_env
print_test_results
