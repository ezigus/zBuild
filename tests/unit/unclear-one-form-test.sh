#!/usr/bin/env bash
# tests/unit/unclear-one-form-test.sh — one way to say what is unclear in the
# issue, and one way to judge a carried question (#2571, ADR-069 §12).
#
# Why: on #1764 design's `UNCLEAR: RQADR-2 | "the holder is in the run-status
# comment" — which comment is this? | …` rode along for days, though the
# issue's Terms answer it. Nothing judged a carried question, and design,
# issue-acceptance and design's check each had their own version of the idea.
# The pieces here are shared by every stage that asks the issue's owner a
# question (scripts/lib/unclear.sh).
#
# U1 [change] the one form `UNCLEAR <id> | "<quote>" | <readings> | ASSUMED: <a>`
#             is read as id, quote, readings and assumption
# U2 [change] a design written before this change, `UNCLEAR: <id> | <question>
#             | <assumed>`, is still read: its question as the readings
# U3 [change] the validator refuses a line with no assumption, a quote not in
#             the issue, and a line in the old form; it passes a good one
# U4 [change] the judge block lists every carried question and the three answers
# U5 [change] the answers: answered (quoting the issue) and not needed are
#             dropped; open is kept; a bad quote, a missing WHY or a missing
#             line is a problem; an id that was not carried is left alone
# U6 [change] a stage's questions in its result (data.unclear): the writer and
#             the reader agree on quotes, backslashes and non-ASCII, with no fork
# U7 [change] a reply's `UNCLEAR <id>:` line starts a unit; an ASSUMED: design
#             wrapped onto the next line is part of its question
# U8 [change] the finding for the raising stage says the question is dropped,
#             and to follow the issue's words
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "one form for what is unclear in the issue (#2571)"
setup_test_env "unclear-one-form"
# shellcheck source=../../scripts/lib/unclear.sh
source "$REPO_ROOT/scripts/lib/unclear.sh"
_has() { declare -F "$1" >/dev/null 2>&1; }

ISSUE='## Terms
- **Run-status comment:** the comment ADR-064 already posts and edits for every run (`scripts/lib/run-status-comment.sh`). Not a new comment.

## Required behavior
- **R2.** The claim holder is in the run-status comment.'
NEW='UNCLEAR RQADR-2 | "The claim holder is in the run-status comment" | a new comment, or the ADR-064 one | ASSUMED: the ADR-064 run-status comment'

print_test_section "U1: the one form"
_p=""; _has zb_unclear_parse_v && zb_unclear_parse_v _p "$NEW"
assert_eq "[U1] id, quote, readings, assumption, form" \
    $'RQADR-2\tThe claim holder is in the run-status comment\ta new comment, or the ADR-064 one\tthe ADR-064 run-status comment\tone' "$_p"
_p=""; _has zb_unclear_parse_v && zb_unclear_parse_v _p '  UNCLEAR  R-1  |  “curly words”  |  x or y  |  assumed:  x  '
assert_eq "[U1] curly quote marks and spacing set aside; ASSUMED in any case" $'R-1\tcurly words\tx or y\tx\tone' "$_p"
_rc=0; _has zb_unclear_parse_v && { zb_unclear_parse_v _p 'UNCLEAR R-1 | "words" | x or y |'; _rc=$?; }
assert_eq "[U1] no assumption: not a question" "1" "$_rc"

print_test_section "U2: the old form is still read"
_p=""; _has zb_unclear_parse_v && zb_unclear_parse_v _p 'UNCLEAR: RQADR-2 | "the holder is in the run-status comment" — which comment is this? | Assumed: the ADR-064 one'
assert_eq "[U2] its question as the readings, no quote, the old form" \
    $'RQADR-2\t\t"the holder is in the run-status comment" — which comment is this?\tthe ADR-064 one\told' "$_p"

print_test_section "U3: the validator"
_w=""; _rc=9; _has zb_unclear_check_v && { zb_unclear_check_v _w "$NEW" "$ISSUE"; _rc=$?; }
assert_eq "[U3] a line in the one form whose quote is in the issue passes" "0:" "$_rc:$_w"
_rc=0; _has zb_unclear_check_v && { zb_unclear_check_v _w 'UNCLEAR RQADR-2 | "The claim holder is in the run-status comment" | a new one, or the old one' "$ISSUE"; _rc=$?; }
assert_eq "[U3] no ASSUMED: refused" "1" "$_rc"
assert_contains "[U3] ...saying so" "$_w" "ASSUMED"
_rc=0; _has zb_unclear_check_v && { zb_unclear_check_v _w 'UNCLEAR RQADR-2 | "the holder lives in a label" | a or b | ASSUMED: a' "$ISSUE"; _rc=$?; }
assert_eq "[U3] a quote not in the issue: refused" "1" "$_rc"
assert_contains "[U3] ...saying it is not the issue's words" "$_w" "not in the issue"
_rc=0; _has zb_unclear_check_v && { zb_unclear_check_v _w 'UNCLEAR: RQADR-2 | which comment? | the ADR-064 one' "$ISSUE"; _rc=$?; }
assert_eq "[U3] the old form, in a new output: refused" "1" "$_rc"
assert_contains "[U3] ...told the one form" "$_w" 'UNCLEAR <id> | "<the issue'"'"'s unclear words, quoted>" | <the readings> | ASSUMED: <the reading chosen and acted on>'
_rc=0; _has zb_unclear_check_v && { zb_unclear_check_v _w 'UNCLEAR RQADR-2 | | a or b | ASSUMED: a' "$ISSUE"; _rc=$?; }
assert_eq "[U3] no quote: refused" "1" "$_rc"

print_test_section "U4: the judge block"
CARRIED="$NEW"$'\n''UNCLEAR: RQOLD-1 | is the flag needed? | it is'
_blk=""; _has zb_unclear_judge_block_v && zb_unclear_judge_block_v _blk "$CARRIED"
_bf="$(tr -s '[:space:]' ' ' <<< "$_blk")"
assert_contains "[U4] each carried question shown" "$_bf" "$NEW"
assert_contains "[U4] ...an old one too" "$_bf" "UNCLEAR: RQOLD-1 | is the flag needed? | it is"
assert_contains "[U4] answered, quoting the issue" "$_bf" "UNCLEAR <id>: answered | WHY: <how the issue answers it> | QUOTE: <the issue's words that answer it>"
assert_contains "[U4] open" "$_bf" "UNCLEAR <id>: open"
assert_contains "[U4] not needed" "$_bf" "UNCLEAR <id>: not needed | WHY: <the requirement it was about is gone or rewritten>"
assert_contains "[U4] one line for every question" "$_bf" "One line for every question"
_blk=""; _has zb_unclear_judge_block_v && zb_unclear_judge_block_v _blk ""
assert_eq "[U4] no question carried: no block" "" "$_blk"

print_test_section "U5: the answers"
REPLY='UNCLEAR RQADR-2: answered | WHY: the Terms define it | QUOTE: the comment ADR-064 already posts and edits for every run
UNCLEAR RQOLD-1: open
UNCLEAR RQZZZ-9: not needed | WHY: never carried'
declare -a K=() DR=(); _pr=""
_has zb_unclear_answers_v && zb_unclear_answers_v K DR _pr "$REPLY" "$CARRIED" "$ISSUE"
assert_eq "[U5] an open question is kept" "RQOLD-1" "${K[*]-}"
assert_eq "[U5] an answered one is dropped, with why and quote" \
    $'RQADR-2\tanswered\tthe Terms define it\tthe comment ADR-064 already posts and edits for every run' "${DR[0]-}"
assert_eq "[U5] ...only the carried ids are read" "1" "${#DR[@]}"
assert_eq "[U5] ...no problem" "" "$_pr"
K=(); DR=(); _pr=""
_has zb_unclear_answers_v && zb_unclear_answers_v K DR _pr $'UNCLEAR RQADR-2: not needed | WHY: R2 is gone from the issue\nUNCLEAR RQOLD-1: open' "$CARRIED" "$ISSUE"
assert_eq "[U5] not needed: dropped" $'RQADR-2\tnot needed\tR2 is gone from the issue\t' "${DR[0]-}"
K=(); DR=(); _pr=""
_has zb_unclear_answers_v && zb_unclear_answers_v K DR _pr $'UNCLEAR RQADR-2: answered | WHY: w | QUOTE: words the issue never says\nUNCLEAR RQOLD-1: not needed' "$CARRIED" "$ISSUE"
assert_contains "[U5] an answer's quote not in the issue is a problem" "$_pr" "RQADR-2"
assert_contains "[U5] ...naming the quote" "$_pr" "not in the issue"
assert_contains "[U5] not needed with no WHY is a problem" "$_pr" "RQOLD-1"
assert_eq "[U5] ...and neither is dropped" "0" "${#DR[@]}"
K=(); DR=(); _pr=""
_has zb_unclear_answers_v && zb_unclear_answers_v K DR _pr 'UNCLEAR RQADR-2: open' "$CARRIED" "$ISSUE"
assert_contains "[U5] a carried question with no line is a problem" "$_pr" "no line for UNCLEAR RQOLD-1"
K=(); DR=(); _pr=""
_has zb_unclear_answers_v && zb_unclear_answers_v K DR _pr $'**UNCLEAR RQADR-2**: open\n- UNCLEAR RQOLD-1: `open`' "$CARRIED" "$ISSUE"
assert_eq "[U5] formatting around the answer is set aside" "RQADR-2 RQOLD-1:" "${K[*]-}:$_pr"

print_test_section "U6: a stage's questions in its result"
declare -a Q=("$NEW" 'UNCLEAR R-3 | "a \back\slash" and “curly” | a or b | ASSUMED: a')
_j=""; _has zb_unclear_result_json_v && zb_unclear_result_json_v _j Q
assert_eq "[U6] the writer's JSON is an array of the lines" "$(printf '%s\n' "${Q[@]}" | jq -Rnc '[inputs]')" "$(jq -c '.' <<< "$_j" 2>/dev/null)"
R="$TEST_TEMP_DIR/intake-result.json"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
stage_result_write "$R" pass "took in the issue" "$(jq -nc --argjson u "${_j:-[]}" '{goal_len: 3, unclear: $u}')"
declare -a BACK=()
_has zb_unclear_result_lines_v && PATH=/nonexistent zb_unclear_result_lines_v BACK "$R"
assert_eq "[U6] the reader gives the lines back, with no program run" "2" "${#BACK[@]}"
assert_eq "[U6] ...quotes kept" "$NEW" "${BACK[0]-}"
assert_eq "[U6] ...backslashes and non-ASCII kept" "${Q[1]}" "${BACK[1]-}"
BACK=(); printf '{"outcome":"pass","data":{"findings":["the word \\"unclear\\":[\\"x\\"] in a finding"]}}\n' > "$TEST_TEMP_DIR/other.json"
_has zb_unclear_result_lines_v && zb_unclear_result_lines_v BACK "$TEST_TEMP_DIR/other.json"
assert_eq "[U6] the word inside another string is not the key" "0" "${#BACK[@]}"

print_test_section "U7: units of a reply and of a design"
_jn=""; zb_reply_join_v _jn $'Steps: ok\nUNCLEAR RQADR-2: answered | WHY: w\nUNCLEAR RQOLD-1: open'
assert_eq "[U7] each UNCLEAR answer is a unit of its own" "3" "$(grep -c . <<< "$_jn")"
D="$TEST_TEMP_DIR/design.md"
printf '# Design\n\nUNCLEAR RQADR-2 | "The claim holder is in the run-status comment" | a new comment,\nor the ADR-064 one\nASSUMED: the ADR-064 run-status comment\n\nProse.\n' > "$D"
declare -a L=()
zb_unclear_list_v L "$D"
assert_eq "[U7] a wrapped question, its ASSUMED: on a line of its own, read whole" \
    $'RQADR-2\tThe claim holder is in the run-status comment\ta new comment, or the ADR-064 one\tthe ADR-064 run-status comment\tone' "${L[0]-}"

print_test_section "U8: the finding for the raising stage"
_f=""; _has zb_unclear_finding_v && zb_unclear_finding_v _f $'RQADR-2\tanswered\tthe Terms define it\tthe comment ADR-064 already posts' DESIGN
assert_contains "[U8] names the question" "$_f" "UNCLEAR RQADR-2:"
assert_contains "[U8] ...the issue answers it, in its words" "$_f" "the comment ADR-064 already posts"
assert_contains "[U8] ...drop it and follow the issue" "$_f" "[FIX IN DESIGN: ACCEPTED IF: the UNCLEAR RQADR-2 line is gone, and the work follows the issue's words where they differ from its assumption]"
_has zb_unclear_finding_v && zb_unclear_finding_v _f $'RQADR-2\tnot needed\tR2 is gone\t' DESIGN
assert_contains "[U8] not needed: drop it" "$_f" "no longer needed: R2 is gone [FIX IN DESIGN: ACCEPTED IF: the UNCLEAR RQADR-2 line is gone]"

# ── U9 (review) ──────────────────────────────────────────────────────────────
# A question written as a list item, or bold, is read like a plain one.
_l9=(); zb_unclear_lines_text_v _l9 $'- UNCLEAR RQ-9 | "the issue words" | a or b | ASSUMED: a\n2. **UNCLEAR RQ-8 | "more words" | c or d | ASSUMED: c**'
assert_eq "[U9] a list-item and a bold question are both read" "2" "${#_l9[@]}"
assert_contains "[U9] ...as the plain line" "${_l9[0]:-}" 'UNCLEAR RQ-9 | "the issue words"'

cleanup_test_env
print_test_results
exit $((FAIL > 0))
