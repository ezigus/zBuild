#!/usr/bin/env bash
# tests/unit/finding-ids-test.sh — every finding has a stable id, and an
# answer names it (#2574 R2; ADR-068 §5 §6, ADR-072 §5, amended 2026-11-20).
#
# Why: answers named a finding by its place in the list ("design finding 2").
# The list changes between tries, so an answer could attach to another
# finding. A finding now has an id in the scheme requirements and SPECs use
# (scripts/lib/item-ids.sh): a code and a number, never reused, removed ones
# counted.
#
# I1 [change] stage_findings_json gives each finding <code>-<n>; the same
#             finding keeps its id when the list changes, a new one takes the
#             number after the highest the code has had, removed ones counted,
#             and a removed id never comes back
# I2 [change] stage_findings_route: a finding has the same id in the stage's
#             own list and in its topic's output; stage_findings_add numbers
#             from the same record
# I3 [change] later stages are shown each finding by its id, and told to
#             answer it by its id
# I4 [change] `ANSWER <id>: …` is read; the old `<label> finding <n>: …` form
#             still is; the kind of each is read
# I5 [change] the finding's text travels with the answer: a stage's result
#             keeps, beside its answers, the text of each finding it answered
# I6 [change] a judge is shown an answered finding's own text, from the
#             answer, after the finding list changed — not the finding that now
#             holds its old place
# I7 [change] an answer whose finding is gone, with no text of its own, is
#             attached to no other finding
# I8 [change] design's check reads an answer by id and finds the item its
#             finding is about
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "every finding has a stable id, and an answer names it (#2574 R2)"
setup_test_env "finding-ids"
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"
# shellcheck source=../../scripts/lib/stage-handoff.sh
source "$REPO_ROOT/scripts/lib/stage-handoff.sh"
# shellcheck source=../../scripts/lib/judge.sh
source "$REPO_ROOT/scripts/lib/judge.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_ids() { jq -r '[.[] | "\(.id)=\(.text)"] | join(" ")' <<< "$1" 2>/dev/null; }

# ── I1 ───────────────────────────────────────────────────────────────────────
print_test_section "I1: ids are stable, never reused, removed ones counted"
D="$TEST_TEMP_DIR/i1"; mkdir -p "$D"
_j="$(printf 'alpha\nbeta\ngamma\n' | stage_findings_json "$D" BUFND)"
assert_eq "[I1] each finding gets <code>-<n>, from 1" "BUFND-1=alpha BUFND-2=beta BUFND-3=gamma" "$(_ids "$_j")"
_j="$(printf 'gamma\nalpha\n' | stage_findings_json "$D" BUFND)"
assert_eq "[I1] a finding keeps its id when the list reorders and shrinks" "BUFND-3=gamma BUFND-1=alpha" "$(_ids "$_j")"
assert_eq "[I1] ...and its place in the list is still n" "1 2" "$(jq -r '[.[].n] | map(tostring) | join(" ")' <<< "$_j")"
_j="$(printf 'delta\nalpha\n' | stage_findings_json "$D" BUFND)"
assert_eq "[I1] a new finding takes the number after the highest, removed ones counted" "BUFND-4=delta BUFND-1=alpha" "$(_ids "$_j")"
_j="$(printf 'beta again\n' | stage_findings_json "$D" BUFND)"
_lacks "[I1] a removed id never comes back" "$(_ids "$_j")" "BUFND-2="
assert_eq "[I1] ...the new finding is BUFND-5" "BUFND-5=beta again" "$(_ids "$_j")"
_j="$(printf 'x\n' | stage_findings_json "$D" DSFND)"
assert_eq "[I1] another code numbers on its own" "DSFND-1=x" "$(_ids "$_j")"
assert_eq "[I1] no input: an empty list" "[]" "$(printf '' | stage_findings_json "$D" BUFND)"

# ── I2 ───────────────────────────────────────────────────────────────────────
print_test_section "I2: one id in every output a finding is in"
D2="$TEST_TEMP_DIR/i2"; mkdir -p "$D2"
_all="$(printf 'design-findings\tthe requirement is wrong\ncode-findings\tthe code misses it\n' | stage_findings_route "$D2" issue-acceptance design-findings IAFND)"
assert_eq "[I2] the stage's own list has ids" "IAFND-1=the requirement is wrong IAFND-2=the code misses it" "$(_ids "$_all")"
assert_eq "[I2] the design output gives its finding the same id" "IAFND-1" "$(jq -r '.data.findings[0].id' "$D2/issue-acceptance-design-result.json")"
assert_eq "[I2] ...and the code output its own" "IAFND-2" "$(jq -r '.data.findings[0].id' "$D2/issue-acceptance-code-result.json")"
_all="$(printf 'code-findings\tthe code misses it\n' | stage_findings_route "$D2" issue-acceptance design-findings IAFND)"
assert_eq "[I2] the next try: the finding still there keeps its id" "IAFND-2" "$(jq -r '.data.findings[0].id' "$D2/issue-acceptance-code-result.json")"
stage_findings_add "$D2/issue-acceptance-code-result.json" '[{"text":"a handed-on finding"}]' IAFND
assert_eq "[I2] stage_findings_add numbers from the same record" "IAFND-2 IAFND-3" \
    "$(jq -r '[.data.findings[].id] | join(" ")' "$D2/issue-acceptance-code-result.json")"

# ── I3 ───────────────────────────────────────────────────────────────────────
print_test_section "I3: a finding is shown by its id"
# shellcheck source=../../scripts/lib/stage-previous-work.sh
source "$REPO_ROOT/scripts/lib/stage-previous-work.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
D3="$TEST_TEMP_DIR/i3"; mkdir -p "$D3"
_f="$(printf 'step 1 has no answer\n' | stage_findings_json "$D3" BUFND)"
stage_result_write "$D3/build-summary.json" unusable "steps" "{\"findings\":$_f}" >/dev/null
_shown="$(_sp_findings_for "$D3/build-summary.json" build build none "")"
assert_eq "[I3] the finding is listed by its id" "- BUFND-1 (opened by build): step 1 has no answer" "$_shown"
stage_result_write "$D3/old.json" fail "old" '{"findings":[{"n":1,"text":"an old one"}]}' >/dev/null
assert_eq "[I3] a finding written before ids is listed as before" "- old finding 1 (opened by old): an old one" \
    "$(_sp_findings_for "$D3/old.json" old old none "")"
assert_contains "[I3] a stage is told to answer a finding by its id" "$(stage_answer_forms)" "ANSWER <its id>: done"

# ── I4 ───────────────────────────────────────────────────────────────────────
print_test_section "I4: answers by id, and the old form"
_a=()
zb_answers_collect_v _a $'ANSWER BUFND-2: not mine — the test must change: tests/x-test.sh: it pins the old label\nANSWER design finding 3: wrong — it holds\nANSWER **BUFND-7 (opened by build)**: done — fixed'
assert_eq "[I4] three answers read" "3" "${#_a[@]}"
assert_eq "[I4] an answer by id is keyed by the id" "BUFND-2: not mine — the test must change: tests/x-test.sh: it pins the old label" "${_a[0]}"
assert_eq "[I4] the old form is still read" "design finding 3: wrong — it holds" "${_a[1]}"
assert_eq "[I4] an id copied as listed, (opened by …) and all, is the id" "BUFND-7: done — fixed" "${_a[2]}"
_k=""; zb_answer_kind_v _k "${_a[0]}"; assert_eq "[I4] its kind: not mine" "not mine" "$_k"
_k=""; zb_answer_kind_v _k "${_a[1]}"; assert_eq "[I4] the old form's kind: wrong" "wrong" "$_k"
_prompt=$'Previous work:\n- BUFND-2 (opened by build): step 1: the line does not do the step\n- BUFND-7 (opened by build): step 2 has no answer\n- BUFND-8 (opened by build): never answered'
_ans=()
zb_answers_finish _ans "$_prompt" $'ANSWER BUFND-2: not mine — the test must change: tests/x-test.sh: why\nANSWER BUFND-7: done — answered it'
assert_eq "[I4] three findings shown, counted by id" "3" "$_ZB_ANS_SHOWN"
assert_eq "[I4] the one not answered stays open, by its id" "BUFND-8" "$_ZB_ANS_MISSING"

# ── I5 ───────────────────────────────────────────────────────────────────────
print_test_section "I5: the finding's text travels with the answer"
_fj=""; zb_answers_findings_json_v _fj _ans
assert_eq "[I5] each answered finding's text, as the stage was shown it" \
    '{"BUFND-2":"step 1: the line does not do the step","BUFND-7":"step 2 has no answer"}' "$(jq -cS . <<< "$_fj")"

# ── I6 / I7 ──────────────────────────────────────────────────────────────────
print_test_section "I6: a judge is shown the answered finding's own text"
D6="$TEST_TEMP_DIR/i6"; mkdir -p "$D6"
_f="$(printf 'the requirement is wrong\nthe code misses RQX-1\n' | stage_findings_json "$D6" IAFND)"
stage_result_write "$D6/issue-acceptance-result.json" fail "two" "{\"findings\":$_f}" >/dev/null
# build answered IAFND-2, shown with its text; then the list changed: IAFND-2
# is gone, and another finding now holds place 2.
_b=(); zb_answers_finish _b "- IAFND-2 (opened by issue-acceptance): the code misses RQX-1" "ANSWER IAFND-2: done — RQX-1 is met now"
_bj=""; zb_answers_findings_json_v _bj _b
stage_result_write "$D6/build-summary.json" pass "built" \
    "{\"answers\":[\"IAFND-2: done — RQX-1 is met now\"],\"answer_findings\":$_bj}" >/dev/null
_f="$(printf 'the requirement is wrong\na new one about RQX-9\n' | stage_findings_json "$D6" IAFND)"
stage_result_write "$D6/issue-acceptance-result.json" fail "two" "{\"findings\":$_f}" >/dev/null
_got=""; judge_answers_to_v _got "$D6" issue-acceptance IAFND
assert_contains "[I6] the answer by id reaches its judge" "$_got" "IAFND-2: done — RQX-1 is met now"
declare -A _af=()
judge_answered_findings_v _af "$_got" "issue-acceptance=$D6/issue-acceptance-result.json"
assert_eq "[I6] the answer is shown with its own finding's text" "the code misses RQX-1" "${_af[IAFND-2]%%$'\x1f'*}"
_held=""; judge_held_entries_v _held "$_got" "issue-acceptance=$D6/issue-acceptance-result.json"
assert_contains "[I6] the earlier-findings entry names the id and its text" "$_held" "- IAFND-2: the code misses RQX-1"
_lacks "[I6] ...never the finding that now holds its place" "$_held" "RQX-9"
print_test_section "I7: an answer whose finding is gone is attached to no other"
declare -A _af7=()
judge_answered_findings_v _af7 "IAFND-9: done — gone" "issue-acceptance=$D6/issue-acceptance-result.json"
assert_eq "[I7] no text: it is not given another finding's" "" "${_af7[IAFND-9]%%$'\x1f'*}"

# ── I8 ───────────────────────────────────────────────────────────────────────
print_test_section "I8: design's check finds the item an answer by id is about"
( # shellcheck source=../../plugins/agent/design/plugin.sh
  source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
  D8="$TEST_TEMP_DIR/i8"; mkdir -p "$D8"
  _f="$(printf 'DSCLM-1: outside — it adds a flag nothing asks for\nSteps: new_owner — core/claim owns it\n' | stage_findings_json "$D8" DSFND)"
  stage_result_write "$D8/design-verdict.json" unusable "check" "{\"findings\":$_f}" >/dev/null
  declare -A first=([DSCLM-1]=1) req_text=() disp=() held=()
  ids=(DSCLM-1)
  _dcov_answered_v disp "DSFND-2: wrong — nothing owns it" "$D8/design-verdict.json" held
  printf 'steps=%s spec=%s\n' "${disp[steps]:-}" "${disp[DSCLM-1]:-}" ) > "$TEST_TEMP_DIR/i8.log" 2>&1
assert_eq "[I8] DSFND-2 is about the steps, and not the SPEC" "steps=DSFND-2: wrong — nothing owns it"$'\n'" spec=" \
    "$(cat "$TEST_TEMP_DIR/i8.log")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
