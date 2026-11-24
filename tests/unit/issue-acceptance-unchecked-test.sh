#!/usr/bin/env bash
# tests/unit/issue-acceptance-unchecked-test.sh — a requirement whose answer
# cannot be checked costs only itself (#2598 R2, ADR-072 §3).
#
# Before, an answer still bad after the re-ask was unusable — every judged
# requirement lost, and the run stopped. Now the judged ones are kept, the one
# that could not be checked is unmet with why, and the stage fails on it.
#
# IU1 [change] a bad quote on one requirement: the others are kept, it is unmet,
#              saying it could not be checked and why, and the answer is used
# IU2 [change] a requirement with no line at all: likewise
# IU3 [guard]  a problem that is no requirement's (a line naming one not
#              listed) still makes the answer unusable
# IU4 [change] an answer that judges no requirement at all is unusable, not
#              every requirement unmet (review on #2598)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a requirement that cannot be checked costs only itself (#2598)"
setup_test_env "issue-acceptance-unchecked"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh"
R="$TEST_TEMP_DIR/repo"; mkdir -p "$R"; printf 'start_stage=1\n' > "$R/run.sh"
REQS=$'- RQ-1: start from the first stage\n- RQ-2: say why it stopped'
ISSUE=$'start from the first stage\nsay why it stopped'

print_test_section "IU1: a bad quote"
_ia_parse $'MET: RQ-1\nUNMET: RQ-2 | WHY: it never says | ACCEPTED IF: it says why | QUOTE: run.sh | stop_reason=none\n' "$REQS" "$ISSUE" "$R"
assert_contains "[IU1] setup: the quote is a problem" "$_IA_PROBLEM" "RQ-2's quote"
_ia_unchecked_to_unmet
assert_eq "[IU1] the answer is used" "" "$_IA_PROBLEM"
assert_eq "[IU1] RQ-2 is unmet" "1" "${#_IA_UNMET[@]}"
assert_contains "[IU1] ...saying it could not be checked" "${_IA_UNMET[0]:-}" "RQ-2: this requirement could not be checked"
assert_contains "[IU1] ...and why" "${_IA_UNMET[0]:-}" "is not in run.sh"

print_test_section "IU2: no line"
_IA_UNCHECKED_WHY=(); _ia_parse $'MET: RQ-1\n' "$REQS" "$ISSUE" "$R"
_ia_unchecked_to_unmet
assert_eq "[IU2] the answer is used" "" "$_IA_PROBLEM"
assert_contains "[IU2] RQ-2 is unmet: it had no line" "${_IA_UNMET[0]:-}" "RQ-2: this requirement could not be checked (it has no line)"

print_test_section "IU3: a problem no requirement owns"
_ia_parse $'MET: RQ-1\nMET: RQ-2\nUNMET: RQ-9 | WHY: x | QUOTE: run.sh | start_stage=1\n' "$REQS" "$ISSUE" "$R"
_ia_unchecked_to_unmet
assert_contains "[IU3] still unusable" "$_IA_PROBLEM" "RQ-9, which is not a requirement listed"

print_test_section "IU4: no requirement judged"
_IA_UNCHECKED_WHY=(); _ia_parse $'I ran out of time and could not judge this change.\n' "$REQS" "$ISSUE" "$R"
_ia_unchecked_to_unmet
assert_contains "[IU4] still unusable" "$_IA_PROBLEM" "it has no line for"
assert_eq "[IU4] ...nothing made unmet" "0" "${#_IA_UNMET[@]}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
