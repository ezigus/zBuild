#!/usr/bin/env bash
# Tests (#2187): lint-disposition-words fails when a stage writes a disposition
# word the engine's closed set does not contain (ADR-054 §6a). The engine refuses
# an off-set word at run time as a structural failure; this catches it in CI.
#
# SPEC-1 [change]: an off-set word in a JSON literal is reported with file:line.
# SPEC-2 [change]: an off-set word passed to a stage's result-writer is reported.
# SPEC-3 [guard] : set words, and computed values ($var, $(…)), pass.
# SPEC-4 [change]: the shipped plugins/ tree passes, and the scan is not vacuous.
# SPEC-5 [change]: wired into `npm run lint` and the CI Lint job.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "lint-disposition-words — stages write only words the engine knows (#2187)"
setup_test_env "lint-disposition-words"
_test_cleanup_hook() { cleanup_test_env; }

LINT="$REPO_ROOT/scripts/lib/lint-disposition-words.sh"
_fx() {   # <name> <plugin.sh body>
    local d="$TEST_TEMP_DIR/$1/agent/fx"; mkdir -p "$d"
    printf '%s\n' "$2" > "$d/plugin.sh"
    printf '%s' "$TEST_TEMP_DIR/$1"
}

print_test_section "SPEC-1: an off-set word in a JSON literal"
_root="$(_fx s1 'x() { printf '"'"'{"result_contract":2,"disposition":"exhausted"}'"'"'; }')"
_out="$(bash "$LINT" "$_root" 2>&1)"; _rc=$?
assert_eq "[SPEC-1] lint exits 1" "1" "$_rc"
assert_contains "[SPEC-1] it names the word" "$_out" "exhausted"
assert_contains "[SPEC-1] it names file:line" "$_out" "plugin.sh:1"

print_test_section "SPEC-2: an off-set word passed to a result-writer"
_root="$(_fx s2 '_fx_write_result "$out" "error" "wedged" "why"')"
_out="$(bash "$LINT" "$_root" 2>&1)"; _rc=$?
assert_eq "[SPEC-2] lint exits 1" "1" "$_rc"
assert_contains "[SPEC-2] it names the word" "$_out" "wedged"

print_test_section "SPEC-2b: an assignment at the start of a line is read, a longer name is not"
_root="$(_fx s2b '_disp="wedged"
set_disposition_hint="whatever"')"
_out="$(bash "$LINT" "$_root" 2>&1)"; _rc=$?
assert_eq "[SPEC-2b] lint exits 1 on the line-start assignment" "1" "$_rc"
assert_contains "[SPEC-2b] it names that word" "$_out" "wedged"
assert_eq "[SPEC-2b] a variable that merely contains the name is not read" "0" "$(grep -c whatever <<< "$_out" || true)"

print_test_section "SPEC-3: set words and computed values pass"
_root="$(_fx s3 '_fx_write_result "$out" "error" "timed_out" "why"
_disp="unusable"
_fx_write_result "$out" "error" "$(router_reason_disposition "$r")" "why"
printf '"'"'{"disposition":"complete"}'"'"'')"
_out="$(bash "$LINT" "$_root" 2>&1)"; _rc=$?
assert_eq "[SPEC-3] lint exits 0" "0" "$_rc"

print_test_section "SPEC-4: the shipped tree"
_out="$(bash "$LINT" 2>&1)"; _rc=$?
assert_eq "[SPEC-4] the shipped plugins/ tree passes" "0" "$_rc"
_n="$(grep -oE '[0-9]+ literal' <<< "$_out" | grep -oE '^[0-9]+' || echo 0)"
assert_gt "[SPEC-4] …having found literal words to check (non-vacuous)" "$_n" "20"

print_test_section "SPEC-5: wiring"
if grep -q 'lint-disposition-words.sh' "$REPO_ROOT/package.json"; then
    assert_pass "[SPEC-5] npm run lint runs it"
else
    assert_fail "[SPEC-5] npm run lint runs it"
fi
if grep -q 'lint-disposition-words.sh' "$REPO_ROOT/.github/workflows/test.yml"; then
    assert_pass "[SPEC-5] the CI Lint job runs it"
else
    assert_fail "[SPEC-5] the CI Lint job runs it"
fi

print_test_results
exit $((FAIL > 0))
