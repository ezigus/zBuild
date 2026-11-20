#!/usr/bin/env bash
# tests/unit/unclear-review-test.sh — the shared questions code holds against
# what a model may write into it (#2571 review, ADR-069 §12, ADR-064 §4).
#
# Why: review of #2571 found that an `answered` only had to quote some words
# of the issue — the question's own words, or "he" — to retire a question;
# that a quote shaped `<file> | <line>` was read as a file under /; that two
# questions on one requirement collapsed into one; that what a model wrote
# reached the issue comment and the PR body with `@name` and `#123` live; and
# that reading a stage's questions was quadratic and read every output in full
# on every status tick.
#
# UR1 [change] answered: a quote inside or equal to the question's own words is
#              refused; a quote of fewer than three words, or of parts of words,
#              is refused; the issue's own words, whole, retire it
# UR2 [change] a quote is matched against the issue's text, never read as a file
# UR3 [change] every retired question is recorded with its WHY and QUOTE
#              (data.unclear_dropped) and shown in the reports as retired
# UR4 [change] one question per requirement id: a second one on the same id is
#              refused, told to use RQ-1a / RQ-1b; carried lines that share an
#              id (written before this rule) are one question to answer
# UR5 [change] text a model wrote cannot mention a user, link an issue, or open
#              a code span or emphasis in the reports
# UR6 [change] a stage's questions are read bounded: at most 50 lines of at most
#              500 characters; a result over 1 MiB, a file that is no stage
#              result, and a result no newer than the run's start are not read
# UR7 [change] a stage carries at most 20 questions; the ones left out are noted
# UR8 [change] the PR description reads the questions by the same rule: only
#              this run's stage results
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "the shared questions code holds (#2571 review)"
setup_test_env "unclear-review"
# shellcheck source=../../scripts/lib/unclear.sh
source "$REPO_ROOT/scripts/lib/unclear.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
_has() { declare -F "$1" >/dev/null 2>&1; }
assert_not_contains() {
    if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "found: $3"; else assert_pass "$1"; fi
}

ISSUE='## Terms
- **Run-status comment:** the comment ADR-064 already posts and edits for every run. Not a new comment.

## Required behavior
- **R1.** The holder is in the run-status comment.'
CARRIED='UNCLEAR RQ-1 | "The holder is in the run-status comment" | a new comment, or the ADR-064 one | ASSUMED: the ADR-064 one'
_ans() {  # _ans <reply> [carried] — K, DR, PR
    K=(); DR=(); PR=""
    zb_unclear_answers_v K DR PR "$1" "${2:-$CARRIED}" "$ISSUE"
}

print_test_section "UR1: what retires a question"
_ans 'UNCLEAR RQ-1: answered | WHY: it says so | QUOTE: The holder is in the run-status comment'
assert_eq "[UR1] the question's own words quoted back: not retired" "0" "${#DR[@]}"
assert_contains "[UR1] ...asked again, saying the quote is the question's own words" "$PR" "the question's own words"
_ans 'UNCLEAR RQ-1: answered | WHY: it says so | QUOTE: run-status comment'
assert_eq "[UR1] a piece of the question's words: not retired" "0" "${#DR[@]}"
_ans 'UNCLEAR RQ-1: answered | WHY: yes | QUOTE: he'
assert_eq "[UR1] a fragment: not retired" "0" "${#DR[@]}"
assert_contains "[UR1] ...at least three words" "$PR" "at least three words"
_ans 'UNCLEAR RQ-1: answered | WHY: yes | QUOTE: omment ADR-064 already pos'
assert_eq "[UR1] parts of words: not retired" "0" "${#DR[@]}"
assert_contains "[UR1] ...not in the issue as whole words" "$PR" "not in the issue"
_ans 'UNCLEAR RQ-1: answered | WHY: the Terms say | QUOTE: the comment ADR-064 already posts'
assert_eq "[UR1] the issue's own words, whole: retired" $'RQ-1\tanswered\tthe Terms say\tthe comment ADR-064 already posts' "${DR[0]-}"
assert_eq "[UR1] ...no problem" "" "$PR"
_ans 'UNCLEAR RQ-1: answered | WHY: the Terms say | QUOTE: Not a new comment.'
assert_eq "[UR1] a quote ending a sentence, with its full stop: retired" "1" "${#DR[@]}"
OLD='UNCLEAR: RQ-1 | "The holder is in the run-status comment" — which comment? | the ADR-064 one'
_ans 'UNCLEAR RQ-1: answered | WHY: it says so | QUOTE: The holder is in the run-status comment' "$OLD"
assert_eq "[UR1] an old-form question's own words quoted back: not retired" "0" "${#DR[@]}"

print_test_section "UR2: the quote is the issue's text, never a file"
_ans 'UNCLEAR RQ-1: answered | WHY: yes | QUOTE: etc/hosts | localhost'
assert_eq "[UR2] a file-shaped quote not in the issue: not retired" "0" "${#DR[@]}"
_w=""; _rc=0; zb_unclear_check_v _w 'UNCLEAR RQ-1 | "etc/hosts" | a or b | ASSUMED: a' "$ISSUE" || _rc=$?
assert_eq "[UR2] a raised quote that names a file, not in the issue: refused" "1" "$_rc"

print_test_section "UR3: every retirement is recorded and shown"
declare -a DROP=($'RQ-1\tanswered\tthe Terms say\tthe comment ADR-064 already posts' $'RQ-2\tnot needed\tR2 is "gone"\t')
Q2='UNCLEAR RQ-2 | "R2" | a or b | ASSUMED: a'
_dj="[]"; _has zb_unclear_dropped_json_v && zb_unclear_dropped_json_v _dj DROP "$CARRIED"$'\n'"$Q2"
assert_eq "[UR3] the record: each retired question by id, how, its WHY and QUOTE, and the question" \
    "$(jq -nc --arg q1 "$CARRIED" --arg q2 "$Q2" '[{id:"RQ-1",verdict:"answered",why:"the Terms say",quote:"the comment ADR-064 already posts",question:$q1},{id:"RQ-2",verdict:"not needed",why:"R2 is \"gone\"",quote:"",question:$q2}]')" \
    "$(jq -c . <<< "$_dj" 2>/dev/null)"
R3="$TEST_TEMP_DIR/r3/intake-result.json"; mkdir -p "${R3%/*}"
stage_result_write "$R3" pass "took in the issue" "$(jq -nc --argjson d "$_dj" '{goal_len: 1, unclear_dropped: $d}')"
declare -a BK=(); _has zb_unclear_dropped_lines_v && PATH=/nonexistent zb_unclear_dropped_lines_v BK "$R3"
assert_eq "[UR3] read back with no fork, whatever the key order" $'RQ-2\tnot needed\tR2 is "gone"\t\t'"$Q2" "${BK[1]-}"
declare -a IN=(); zb_unclear_results_in_v IN "${R3%/*}"
assert_eq "[UR3] a result with only retired questions is found" "1" "${#IN[@]}"
_m=""; zb_unclear_markdown_v _m "" "$R3"
assert_contains "[UR3] the reports say what was retired" "$_m" "**Questions intake retired**"
assert_contains "[UR3] ...answered, with its WHY and QUOTE" "$_m" '- RQ-1: answered — the Terms say — "the comment ADR-064 already posts"'
assert_contains "[UR3] ...not needed, with its WHY" "$_m" '- RQ-2: not needed — R2 is "gone"'
R3b="$TEST_TEMP_DIR/r3b/lens-result.json"; mkdir -p "${R3b%/*}"
printf '{"data":{"unclear_dropped":[{"question":"q","quote":"","why":"w {x}","verdict":"not needed","id":"RQ-7","n":1}]}}\n' > "$R3b"
BK=(); _has zb_unclear_dropped_lines_v && zb_unclear_dropped_lines_v BK "$R3b"
assert_eq "[UR3] another writer's key order and a number field" $'RQ-7\tnot needed\tw {x}\t\tq' "${BK[0]-}"

print_test_section "UR4: one question per requirement id"
declare -A SEEN=(); _w=""; _rc=0
zb_unclear_check_v _w 'UNCLEAR RQ-1 | "The holder" | a or b | ASSUMED: a' "$ISSUE" SEEN || _rc=$?
assert_eq "[UR4] the first question on RQ-1 passes" "0" "$_rc"
_rc=0; zb_unclear_check_v _w 'UNCLEAR RQ-1 | "run-status comment" | c or d | ASSUMED: c' "$ISSUE" SEEN || _rc=$?
assert_eq "[UR4] a second on RQ-1: refused" "1" "$_rc"
assert_contains "[UR4] ...told to give each its own id" "$_w" "RQ-1a"
_rc=0; zb_unclear_check_v _w 'UNCLEAR RQ-1b | "run-status comment" | c or d | ASSUMED: c' "$ISSUE" SEEN || _rc=$?
assert_eq "[UR4] RQ-1b passes" "0" "$_rc"
DUP=$'UNCLEAR RQ-1 | "The holder" | a or b | ASSUMED: a\nUNCLEAR RQ-1 | "run-status comment" | c or d | ASSUMED: c'
_ans 'UNCLEAR RQ-1: open' "$DUP"
assert_eq "[UR4] carried lines sharing an id: one answer, no problem" "RQ-1:" "${K[*]-}:$PR"

print_test_section "UR5: model text is inert in the reports"
declare -a EV=('UNCLEAR RQ-5 | "ping @octocat on #123" | a `code` or *bold* | ASSUMED: see https://evil.example/x')
R5="$TEST_TEMP_DIR/r5/lens-result.json"; mkdir -p "${R5%/*}"
_j5="[]"; zb_unclear_result_json_v _j5 EV
stage_result_write "$R5" pass "judged" "$(jq -nc --argjson u "$_j5" '{unclear: $u}')"
_m5=""; zb_unclear_markdown_v _m5 "" "$R5"
assert_contains "fixture: the question is shown" "$_m5" "RQ-5"
assert_not_contains "[UR5] no live @mention" "$_m5" "@octocat"
assert_not_contains "[UR5] no live issue link" "$_m5" "#123"
assert_contains "[UR5] backticks escaped" "$_m5" 'a \`code\`'
assert_contains "[UR5] emphasis escaped" "$_m5" '\*bold\*'
assert_not_contains "[UR5] no live link" "$_m5" "https://evil"

print_test_section "UR6: read bounded"
BIG="$TEST_TEMP_DIR/r6/intake-result.json"; mkdir -p "${BIG%/*}"
_long="$(printf '%*s' 900 '' | tr ' ' x)"
{ printf '{"outcome":"pass","data":{"unclear":['
  for i in $(seq 1 120); do printf '%s"UNCLEAR RQ-%d | \\"w\\" | a or b | ASSUMED: %s"' "$([[ $i -gt 1 ]] && printf ,)" "$i" "$_long"; done
  printf ']}}\n'; } > "$BIG"
declare -a B6=(); PATH=/nonexistent zb_unclear_result_lines_v B6 "$BIG"
assert_eq "[UR6] at most 50 lines read" "50" "${#B6[@]}"
assert_eq "[UR6] ...each at most 500 characters" "500" "${#B6[0]}"
HUGE="$TEST_TEMP_DIR/r6h/intake-result.json"; mkdir -p "${HUGE%/*}"
{ printf '{"data":{"unclear":["UNCLEAR RQ-1 | \\"w\\" | a or b | ASSUMED: a"],"pad":"'; printf '%*s' 1100000 ''; printf '"}}\n'; } > "$HUGE"
declare -a I6=(); zb_unclear_results_in_v I6 "${HUGE%/*}"
assert_eq "[UR6] a result over 1 MiB is not read" "0" "${#I6[@]}"
OD="$TEST_TEMP_DIR/r6o"; mkdir -p "$OD"
printf '{"data":{"unclear":["UNCLEAR RQ-1 | \\"w\\" | a or b | ASSUMED: a"]}}\n' > "$OD/notes.json"
I6=(); zb_unclear_results_in_v I6 "$OD"
assert_eq "[UR6] a file that is no stage result is not read" "0" "${#I6[@]}"
SD="$TEST_TEMP_DIR/r6s"; mkdir -p "$SD"
printf '{"data":{"unclear":["UNCLEAR RQ-1 | \\"w\\" | a or b | ASSUMED: a"]}}\n' > "$SD/intake-result.json"
touch "$SD/run-start"; touch -r "$SD/run-start" "$SD/intake-result.json"
I6=(); zb_unclear_results_in_v I6 "$SD" "$SD/run-start"
assert_eq "[UR6] a result with the run start's own time is not this run's" "0" "${#I6[@]}"

print_test_section "UR7: at most 20 carried"
declare -a MANY=(); for i in $(seq 1 23); do MANY+=("UNCLEAR RQ-$i | \"w\" | a or b | ASSUMED: a"); done
_n7=""; _j7="[]"; zb_unclear_result_json_v _j7 MANY _n7
assert_eq "[UR7] the result carries 20" "20" "$(jq 'length' <<< "$_j7" 2>/dev/null)"
assert_contains "[UR7] ...the three left out are noted" "$_n7" "3 more"
declare -a C7=("${MANY[@]}"); _n7=""; _has zb_unclear_cap_v && zb_unclear_cap_v C7 _n7
assert_eq "[UR7] the shared cap keeps the first 20" "20:UNCLEAR RQ-20" "${#C7[@]}:${C7[19]%% |*}"

print_test_section "UR8: the PR description, by the same rule"
# shellcheck source=../../plugins/tool/pr-open/plugin.sh
source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh" >/dev/null 2>&1
P8="$TEST_TEMP_DIR/p8"; mkdir -p "$P8/artifacts" "$P8/runtime"
printf '{"data":{"unclear":["UNCLEAR RQ-81 | \\"old\\" | a or b | ASSUMED: a"]}}\n' > "$P8/artifacts/intake-result.json"
printf '{"data":{"unclear":["UNCLEAR RQ-82 | \\"notes\\" | a or b | ASSUMED: a"]}}\n' > "$P8/artifacts/notes.json"
touch "$P8/runtime/run-start"; touch -r "$P8/runtime/run-start" "$P8/artifacts/intake-result.json"
jq -n --arg a "$P8/artifacts/intake-result.json" --arg b "$P8/artifacts/notes.json" '{inputs:{intake_result:$a, notes:$b}}' > "$P8/inputs.json"
_p8=""; _p8="$(state_dir="$P8" ZBUILD_STAGE_INPUTS="$P8/inputs.json" _pr_open_questions)"
assert_not_contains "[UR8] a result from before this run's start is not shown" "$_p8" "RQ-81"
assert_not_contains "[UR8] a file that is no stage result is not read" "$_p8" "RQ-82"
touch "$P8/artifacts/intake-result.json"
_p8="$(state_dir="$P8" ZBUILD_STAGE_INPUTS="$P8/inputs.json" _pr_open_questions)"
assert_contains "[UR8] this run's result is shown" "$_p8" "RQ-81"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
