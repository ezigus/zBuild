#!/usr/bin/env bash
# tests/unit/lens-unclear-test.sh — a lens says what it finds unclear in the
# issue in the one form, and its own next call judges every question it
# carried (#2571 R3, ADR-038, ADR-069 §12).
#
# Why: a lens could only say the issue is wrong (`fix: issue`, which stops the
# run). An issue whose words could mean either of two things is not wrong: the
# lens picks a reading, judges by it, and says so.
#
# LU1 [change] the lens is told the one form, that a question goes in its
#              report's "unclear" list and is no finding, and that an issue
#              that is wrong is still fix: issue
# LU2 [change] a good question: the lens's verdict stands, and the question is
#              in its result, data.unclear; it reaches design as a finding
#              that blocks nothing, as issue-acceptance's do — a question is
#              never free; one the lens carried is no new finding
# LU3 [change] a line with no ASSUMED, or whose quote is not in the issue, is
#              asked again, saying what is wrong
# LU4 [guard]  a finding that the issue is wrong still stops the run
# LU5 [change] the next call is shown each carried question and the answer
#              forms; open is kept, answered is dropped; no answer is asked
#              again, naming it
# LU6 [change] a lens whose call fails keeps the carried questions in its result
# LU7 [change] a question line never makes the report unusable: one written as
#              a list item is read; after the one re-ask the findings are
#              kept, a still-bad new line is left out with a note, and a
#              carried question with no usable answer is kept open with a note;
#              a re-ask answered worse leaves the first report
# LU8 [change] a carried question the lens retires is recorded in its result,
#              data.unclear_dropped, with its WHY and QUOTE
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a lens's unclear points, in the one form, judged when carried (#2571)"
setup_test_env "lens-unclear"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh" 2>/dev/null
set +e
zb_test_lens_jobs lu
assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then assert_fail "$1" "output unexpectedly has: $3"; else assert_pass "$1"; fi
}

_RQ="$TEST_TEMP_DIR/calls"
_reset() { rm -rf "$_RQ"; mkdir -p "$_RQ"; printf '0' > "$_RQ/n"; printf '%s\n' "$@" > "$_RQ/replies"; }
# shellcheck disable=SC2329  # invoked by the sourced plugin
route_to_model() { zb_test_lens_check_answer "$2" && return 0
    local n r; n=$(( $(cat "$_RQ/n") + 1 )); printf '%s' "$n" > "$_RQ/n"
    printf '%s' "$2" > "$_RQ/prompt-$n.txt"
    r="$(sed -n "${n}p" "$_RQ/replies")"
    [[ "$r" == RC=* ]] && return "${r#RC=}"
    printf '%s' "$r"
}
_calls() { cat "$_RQ/n"; }
_flat() { tr -s '[:space:]' ' ' < "$1" 2>/dev/null; }

artifact_dir="$TEST_TEMP_DIR/artifacts"; mkdir -p "$artifact_dir"
scope="$TEST_TEMP_DIR/scope.md"; printf '+ core/\n' > "$scope"
evidence="$artifact_dir/diff.patch"
printf 'diff --git a/core/x.sh b/core/x.sh\n+ new line\n' > "$evidence"
# The issue as intake gives it: data.issue_text of its result.
zb_test_issue_output "$artifact_dir" "Add a flag. Refuse a missing config file. On a missing config file, exit with an error." >/dev/null
out="$artifact_dir/lens-lu.json"
_lens() { _review_lens_run_inner lu "$scope" "$evidence" "$out" "$artifact_dir" >/dev/null 2>&1; }
_res() { jq -r "$1" "$out" 2>/dev/null || echo MISSING; }

Q='UNCLEAR RQCNFG-1 | \"Refuse a missing config file\" | exit with an error, or warn and go on | ASSUMED: exit with an error'
QL='UNCLEAR RQCNFG-1 | "Refuse a missing config file" | exit with an error, or warn and go on | ASSUMED: exit with an error'
_rep() { printf '{"score":10,"findings":[]%s}' "${1:+,$1}"; }

print_test_section "LU1/LU2: a question, in the one form"
rm -f "$out" "${out%.json}-judged.json"
_reset "$(_rep "\"unclear\":[\"$Q\"]")"
_lens
_p="$(_flat "$_RQ/prompt-1.txt")"
assert_contains "[LU1] the lens is told the one form" "$_p" \
    "UNCLEAR <id> | \"<the issue's unclear words, quoted>\" | <the readings> | ASSUMED: <the reading chosen and acted on>"
assert_contains "[LU1] ...that a question goes in the report's unclear list, and is no finding" "$_p" \
    "In this report each such line is a string in the \"unclear\" list, not a finding"
assert_contains "[LU1] ...and that an issue that is wrong is still fix: issue" "$_p" \
    "An issue whose words could mean either of two things is not wrong: it is a question, never fix: issue."
assert_eq "[LU2] the lens passes" "pass" "$(_res .outcome)"
assert_eq "[LU2] ...on the first answer" "1" "$(_calls)"
assert_eq "[LU2] the question is in the lens's result, data.unclear" "$QL" "$(_res '(.data.unclear // [])[]')"
_dtexts() { jq -r '(.data.findings // [])[] | "\(.blocking) \(.text)"' "${out%.json}-design-result.json" 2>/dev/null; }
assert_contains "[LU2] ...and reaches design as a finding, saying the lens judged by the assumption" "$(_dtexts)" \
    "false The issue is unclear here, and the lu lens judged by the assumption: $QL"
assert_eq "[LU2] ...which blocks nothing: design's output passes" "pass" "$(jq -r .outcome "${out%.json}-design-result.json" 2>/dev/null)"
assert_eq "[LU2] ...and reaches no other stage" "0" "$(cat "${out%.json}"-code-result.json "${out%.json}"-test-result.json 2>/dev/null | jq -s '[.[].data.findings // [] | .[]] | length' 2>/dev/null || echo 0)"

print_test_section "LU3: a bad line is asked again"
rm -f "$out" "${out%.json}-judged.json"
_reset "$(_rep '"unclear":["UNCLEAR RQCNFG-1 | \"Refuse a missing config file\" | exit, or warn"]')" "$(_rep "\"unclear\":[\"$Q\"]")"
_lens
assert_eq "[LU3] no ASSUMED: asked again" "2" "$(_calls)"
assert_contains "[LU3] ...saying so" "$(_flat "$_RQ/prompt-2.txt")" "has no ASSUMED"
assert_eq "[LU3] ...and the second answer's question is kept" "$QL" "$(_res '(.data.unclear // [])[]')"
rm -f "$out" "${out%.json}-judged.json"
_reset "$(_rep '"unclear":["UNCLEAR RQCNFG-1 | \"Configs are optional\" | exit, or warn | ASSUMED: exit"]')" "$(_rep "\"unclear\":[\"$Q\"]")"
_lens
assert_eq "[LU3] a quote not in the issue: asked again" "2" "$(_calls)"
assert_contains "[LU3] ...saying so" "$(_flat "$_RQ/prompt-2.txt")" "quotes words that are not in the issue: Configs are optional"

print_test_section "LU4: an issue that is wrong still stops the run"
rm -f "$out" "${out%.json}-judged.json"
_TPL_STAGE_FAIL_ON_lens_lu="high critical"; export ZBUILD_CURRENT_STAGE=lens_lu
_reset '{"score":2,"findings":[{"file":"core/x.sh","severity":"high","message":"the issue contradicts ADR-040","quote":"new line","trigger":"every run","accepted_if":"the issue agrees with ADR-040","introduced":true,"fix":"issue"}]}'
_lens
assert_eq "[LU4] fix: issue at a fail_on severity: misconfigured" "misconfigured" "$(_res .outcome)"
unset ZBUILD_CURRENT_STAGE _TPL_STAGE_FAIL_ON_lens_lu

print_test_section "LU5: the carried question, judged by the next call"
rm -f "$out" "${out%.json}-judged.json"
_reset "$(_rep "\"unclear\":[\"$Q\"]")"; _lens
_reset "$(_rep '"unclear_answers":["UNCLEAR RQCNFG-1: open"]')"; _lens
_p="$(_flat "$_RQ/prompt-1.txt")"
assert_contains "[LU5] the next call is shown the carried question" "$_p" "$QL"
assert_contains "[LU5] ...and the answer forms" "$_p" \
    "UNCLEAR <id>: answered | WHY: <how the issue answers it> | QUOTE: <the issue's words that answer it>"
assert_contains "[LU5] ...to give in its report's unclear_answers list" "$_p" "\"unclear_answers\""
assert_eq "[LU5] open: the question is kept" "$QL" "$(_res '(.data.unclear // [])[]')"
assert_eq "[LU5] ...and is no new finding for design" "" "$(_dtexts)"
rm -f "${out%.json}-judged.json"
_reset "$(_rep '')" "$(_rep '"unclear_answers":["UNCLEAR RQCNFG-1: open"]')"; _lens
assert_eq "[LU5] no answer: asked again" "2" "$(_calls)"
assert_contains "[LU5] ...naming it" "$(_flat "$_RQ/prompt-2.txt")" "no line for UNCLEAR RQCNFG-1"
rm -f "${out%.json}-judged.json"
_reset "$(_rep '"unclear_answers":["UNCLEAR RQCNFG-1: answered | WHY: the issue says to exit | QUOTE: exit with an error"]')"; _lens
assert_eq "[LU5] answered: the question is dropped" "" "$(_res '(.data.unclear // [])[]')"

print_test_section "LU6: a failed call keeps the questions"
rm -f "$out" "${out%.json}-judged.json"
_reset "$(_rep "\"unclear\":[\"$Q\"]")"; _lens
rm -f "${out%.json}-judged.json"
_reset "RC=1"; _lens
assert_eq "[LU6] the call failed: no pass" "no" "$([[ "$(_res .outcome)" == pass ]] && echo yes || echo no)"
assert_eq "[LU6] ...and the result keeps the carried question" "$QL" "$(_res '(.data.unclear // [])[]')"

print_test_section "LU7: a question line never makes the report unusable"
_notes() { jq -r '(.data.notes // [])[]' "$out" 2>/dev/null; }
rm -f "$out" "${out%.json}-judged.json"
_reset "$(_rep "\"unclear\":[\"- $Q\"]")"; _lens
assert_eq "[LU7] a question written as a list item is read: a pass" "pass" "$(_res .outcome)"
assert_eq "[LU7] ...on the first answer" "1" "$(_calls)"
assert_eq "[LU7] ...kept without its list mark" "$QL" "$(_res '(.data.unclear // [])[]')"
rm -f "$out" "${out%.json}-judged.json"
_BADQ='"unclear":["UNCLEAR RQCNFG-1 | \"Refuse a missing config file\" | exit, or warn"]'
_reset "$(_rep "$_BADQ")" "$(_rep "$_BADQ")"; _lens
assert_eq "[LU7] a new line still bad after the re-ask: asked once more, no more" "2" "$(_calls)"
assert_eq "[LU7] ...the report is kept: a pass" "pass" "$(_res .outcome)"
assert_eq "[LU7] ...the line is left out" "" "$(_res '(.data.unclear // [])[]')"
assert_contains "[LU7] ...and the result notes it" "$(_notes)" "an UNCLEAR line was left out, still not in its form after it was asked again: UNCLEAR RQCNFG-1"
rm -f "$out" "${out%.json}-judged.json"
_reset "$(_rep "\"unclear\":[\"$Q\"]")"; _lens
rm -f "${out%.json}-judged.json"
_reset "$(_rep '')" "$(_rep '')"; _lens
assert_eq "[LU7] a carried question with no answer on either try: the report is kept" "pass" "$(_res .outcome)"
assert_eq "[LU7] ...the question is kept open" "$QL" "$(_res '(.data.unclear // [])[]')"
assert_contains "[LU7] ...and the result notes it" "$(_notes)" "UNCLEAR RQCNFG-1: no usable answer after it was asked again — kept open"
rm -f "$out" "${out%.json}-judged.json"
_reset "$(_rep "$_BADQ")" "not json at all"; _lens
assert_eq "[LU7] a re-ask answered worse: the first report stands" "pass" "$(_res .outcome)"
assert_eq "[LU7] ...after the one re-ask" "2" "$(_calls)"

print_test_section "LU8: a retired question is recorded"
rm -f "$out" "${out%.json}-judged.json"
_reset "$(_rep "\"unclear\":[\"$Q\"]")"; _lens
rm -f "${out%.json}-judged.json"
_reset "$(_rep '"unclear_answers":["UNCLEAR RQCNFG-1: answered | WHY: the issue says to exit | QUOTE: exit with an error"]')"; _lens
assert_eq "[LU8] recorded by its id" "RQCNFG-1" "$(_res '.data.unclear_dropped[0].id')"
assert_eq "[LU8] ...with how it was retired" "answered" "$(_res '.data.unclear_dropped[0].verdict')"
assert_eq "[LU8] ...its WHY" "the issue says to exit" "$(_res '.data.unclear_dropped[0].why')"
assert_eq "[LU8] ...its QUOTE" "exit with an error" "$(_res '.data.unclear_dropped[0].quote')"
assert_eq "[LU8] ...and the question it retired, as carried" "$QL" "$(_res '.data.unclear_dropped[0].question')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
