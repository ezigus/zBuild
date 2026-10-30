#!/usr/bin/env bash
# tests/unit/stage-prompt-reask-test.sh — a reply that cannot be used is asked
# again with what was wrong and the reply itself (ADR-060 §6, amended).
#
#   Q1 [change]: stage_prompt_reask gives the same prompt, then what was wrong
#                with the reply, then the reply
#   Q2 [change]: it tells the model to fix only what is named — its work stands
#   Q3 [guard] : a reply over the limit is cut, with a marker saying so
#   Q4 [guard] : the re-ask keeps the contract's sections in order
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"

print_test_header "stage prompt — a reply that cannot be used is asked again (ADR-060 §6)"
setup_test_env "stage-prompt-reask"

# ─── Q1 ──────────────────────────────────────────────────────────────────────
_p="$(stage_prompt_compose_parts $'## What you own\nReview it.\n## What you judge against\nThe diff.\n## What you must not do\nNothing else.')"
_bad='{"findings":[{"message":"until.{stage,field,op,value} all required" is wrong"}]}'
_q="$(stage_prompt_reask "$_p" "it is not valid JSON: jq says Invalid literal at line 1, column 70" "$_bad" 2>/dev/null)"
assert_eq "Q1: the re-ask starts with the same prompt" "$_p" "${_q:0:${#_p}}"
assert_contains "Q1: the re-ask says what was wrong" "$_q" "it is not valid JSON: jq says Invalid literal at line 1, column 70"
assert_contains "Q1: the re-ask carries the reply itself" "$_q" "$_bad"
_after="${_q:${#_p}}"
_wpos="${_after%%it is not valid JSON*}"; _rpos="${_after%%"$_bad"*}"
if [[ ${#_wpos} -lt ${#_rpos} ]]; then
    assert_pass "Q1: what was wrong comes before the reply"
else
    assert_fail "Q1: what was wrong comes before the reply" "order: reply first"
fi

# ─── Q2 ──────────────────────────────────────────────────────────────────────
assert_contains "Q2: the model is told to answer again in the form asked for" "$_q" "Answer again, in the form asked for above"
assert_contains "Q2: the model is told its work stands" "$_q" "Do not do the work again"

# ─── Q3 ──────────────────────────────────────────────────────────────────────
_big="$(printf '%*s' 70000 '' | tr ' ' 'x')"
_q3="$(stage_prompt_reask "$_p" "too long" "$_big" 2>/dev/null)"
if [[ ${#_q3} -lt $(( ${#_p} + 70000 )) ]]; then
    assert_pass "Q3: a long reply is cut"
else
    assert_fail "Q3: a long reply is cut" "length ${#_q3}"
fi
assert_contains "Q3: the cut is marked" "$_q3" "[… the rest of your reply is cut]"

# ─── Q4 ──────────────────────────────────────────────────────────────────────
printf '%s\n' "$_q" > "$TEST_TEMP_DIR/q4.md"
_rc=0; stage_prompt_check "$TEST_TEMP_DIR/q4.md" || _rc=$?
assert_eq "Q4: the re-ask keeps the contract's order" "0" "$_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
