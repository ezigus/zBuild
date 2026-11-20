#!/usr/bin/env bash
# tests/unit/issue-acceptance-unclear-test.sh — issue-acceptance says what it
# finds unclear in the issue in the one form, still judges every requirement,
# and its own next call judges every question it carried (#2571 R3 R4,
# ADR-072 §3, ADR-069 §12).
#
# Why: issue-acceptance's UNSURE was a version of its own of "the issue is
# unclear" — no quote of the issue, no reading picked, and it stood in for the
# verdict: a requirement it was unsure of was neither met nor unmet.
#
# IA1 [change] the prompt offers the one form, not UNSURE, and says a question
#              never takes the place of the requirement's MET or UNMET line
# IA2 [change] a good UNCLEAR line: the verdict stands (pass), the line is in
#              data.unclear, and it is a finding routed as an unmarked UNSURE
#              was — to design, test and code — saying the assumption
# IA3 [change] an UNCLEAR line is no verdict: a requirement with only a
#              question is asked again
# IA4 [change] a line with no ASSUMED, or whose quote is not in the issue, is
#              asked again, saying what is wrong
# IA5 [guard]  an UNSURE line in the old form is still read, never lost: a fail,
#              in data.unsure, a finding
# IA6 [change] the next call is shown each carried question and the answer
#              forms; answered is dropped; open is kept and is no new finding;
#              no answer line is asked again, naming it
# IA7 [change] a try whose call fails keeps the carried questions in its result
# IA8 [change] a question line never makes the answer unusable: one written as
#              a list item is read; after the one re-ask the verdicts are kept,
#              a still-bad new line is left out with a note, and a carried
#              question with no usable answer is kept open with a note; a
#              re-ask whose answer is worse leaves the first answer's verdicts
# IA9 [change] a carried question it retires is recorded in its result,
#              data.unclear_dropped, with its WHY and QUOTE, never lost silently
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "issue-acceptance: unclear points in the one form, judged when carried (#2571)"
setup_test_env "issue-acceptance-unclear"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR"
(cd "$XR" && /usr/bin/git init -q && printf 'x\n' > f && /usr/bin/git add f \
    && /usr/bin/git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$XR"

ISSUE_TEXT="Add a flag. Refuse a missing config file. On a missing config file, exit with an error."
S="$TEST_TEMP_DIR/s"; A="$S/artifacts"; IN="$S/inputs"; mkdir -p "$A" "$IN"; printf '{}' > "$S/pipeline-state.json"
# Each input by its writer: the issue, intake's requirements, a design, a test run.
zb_test_issue_output "$IN" "$ISSUE_TEXT" >/dev/null
(
    # shellcheck source=../../plugins/agent/intake/plugin.sh
    source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
    route_to_model() {
        if [[ "$2" == *"check a list of requirements"* ]]; then printf 'MISSING: none\n'
        else printf 'REQUIREMENT: RQFLAG-1 Add a flag.\nREQUIREMENT: RQCNFG-1 Refuse a missing config file.\n'; fi
    }
    _intake_write_requirements "$IN" "$(jq -nc --arg b "$ISSUE_TEXT" '{title: "Add a flag", body: $b}')"
) >/dev/null 2>&1
printf '%s\n' '# Design' '```acceptance' 'DSFLAG-1[code]: a flag is accepted' 'DSCNFG-1[code]: a missing config is refused' 'WIRING: none' '```' > "$IN/design.md"
printf '%s\n' 'diff --git a/p.sh b/p.sh' '+flag=1' > "$IN/diff.patch"
zb_test_test_run_output "$IN" pass 1 0 >/dev/null
jq -n --arg i "$IN/intake-result.json" --arg r "$IN/requirements.json" --arg d "$IN/design.md" \
    --arg p "$IN/diff.patch" --arg t "$IN/test-results.json" \
    '{inputs: {a: $i, r: $r, b: $d, c: $p, d: $t}}' > "$S/stage-inputs.json"
export ZBUILD_STAGE_INPUTS="$S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$A"

# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" 2>/dev/null
set +e
_N="$TEST_TEMP_DIR/n"; _P="$TEST_TEMP_DIR/p"; _R1=""; _R2=""; _RC=0
route_to_model() {
    local n; n=$(( $(cat "$_N" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
    [[ "$_RC" -eq 0 ]] || return "$_RC"
    if [[ $n -eq 1 ]]; then printf '%s\n' "$_R1"; else printf '%s\n' "${_R2:-$_R1}"; fi
}
resolve_tier() { printf 'T2'; }
# _ia [fresh] — one run; "fresh" first clears the last result and kept answer.
_ia() {
    [[ "${1:-}" == fresh ]] && rm -f "$A/issue-acceptance-result.json" "$A/issue-acceptance-judged.json"
    rm -f "$_N" "$_P".*
    issue_acceptance_run issue-acceptance "$S/pipeline-state.json" >/dev/null 2>&1
    OUT="$(jq -r '.outcome // "MISSING"' "$A/issue-acceptance-result.json" 2>/dev/null || echo MISSING)"
    CALLS="$(cat "$_N" 2>/dev/null || echo 0)"
}
_res() { jq -r "$1" "$A/issue-acceptance-result.json" 2>/dev/null || echo MISSING; }
_texts() { jq -r '(.data.findings // [])[] | .text' "$1" 2>/dev/null; }
_flat() { tr -s '[:space:]' ' ' < "$1" 2>/dev/null; }
assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then assert_fail "$1" "output unexpectedly has: $3"; else assert_pass "$1"; fi
}

Q='UNCLEAR RQCNFG-1 | "Refuse a missing config file" | exit with an error, or warn and go on | ASSUMED: exit with an error'
MET2=$'MET: RQFLAG-1\nMET: RQCNFG-1'

print_test_section "IA1: the prompt"
_R1="$MET2"; _ia fresh
_p="$(_flat "$_P.1")"
assert_contains "[IA1] the prompt offers the one form" "$_p" \
    "UNCLEAR <id> | \"<the issue's unclear words, quoted>\" | <the readings> | ASSUMED: <the reading chosen and acted on>"
assert_not_contains "[IA1] ...not UNSURE" "$_p" "UNSURE: <id> | WHY:"
assert_contains "[IA1] a question never takes the place of the verdict" "$_p" \
    "A question is never a verdict: write the requirement's MET: or UNMET: line too, judged by the reading you assumed."

print_test_section "IA2: a question, and the verdict stands"
_R1="$MET2"$'\n'"$Q"; _ia fresh
assert_eq "[IA2] every requirement is met: a pass" "pass" "$OUT"
assert_eq "[IA2] ...on the first answer" "1" "$CALLS"
assert_eq "[IA2] the question is in data.unclear, as written" "$Q" "$(_res '(.data.unclear // [])[]')"
for _o in design test code; do
    assert_contains "[IA2] it is a finding for $_o, as an unmarked UNSURE was" \
        "$(_texts "$A/issue-acceptance-$_o-result.json")" "ASSUMED: exit with an error"
done
assert_contains "[IA2] ...saying the issue is unclear and the verdict went on the assumption" \
    "$(_texts "$A/issue-acceptance-design-result.json")" "The issue is unclear here, and issue-acceptance judged by the assumption:"

print_test_section "IA3: a question is no verdict"
_R1=$'MET: RQFLAG-1\n'"$Q"; _R2="$MET2"$'\n'"$Q"; _ia fresh
assert_eq "[IA3] a requirement with only a question is asked again" "2" "$CALLS"
assert_contains "[IA3] ...naming it" "$(_flat "$_P.2")" "it has no line for RQCNFG-1"

print_test_section "IA4: a bad line is asked again"
_R1="$MET2"$'\nUNCLEAR RQCNFG-1 | "Refuse a missing config file" | exit, or warn'; _R2="$MET2"$'\n'"$Q"; _ia fresh
assert_eq "[IA4] no ASSUMED: asked again" "2" "$CALLS"
assert_contains "[IA4] ...saying so" "$(_flat "$_P.2")" "has no ASSUMED"
_R1="$MET2"$'\nUNCLEAR RQCNFG-1 | "Configs are optional" | exit, or warn | ASSUMED: exit'; _ia fresh
assert_eq "[IA4] a quote not in the issue: asked again" "2" "$CALLS"
assert_contains "[IA4] ...saying so" "$(_flat "$_P.2")" "quotes words that are not in the issue: Configs are optional"

print_test_section "IA5: an UNSURE in the old form is still read"
_R1=$'MET: RQFLAG-1\nUNSURE: RQCNFG-1 | WHY: cannot tell which refusal is meant | ACCEPTED IF: a missing config file is refused | QUOTE: Refuse a missing config file'
_R2=""; _ia fresh
assert_eq "[IA5] an old UNSURE line is still a fail" "fail" "$OUT"
assert_contains "[IA5] ...listed in data.unsure" "$(_res '.data.unsure[0]')" "RQCNFG-1: cannot tell which refusal is meant"
assert_contains "[IA5] ...and a finding" "$(_texts "$A/issue-acceptance-result.json")" "RQCNFG-1: cannot tell which refusal is meant"

print_test_section "IA6: the carried question, judged by the next call"
_R1="$MET2"$'\n'"$Q"; _R2=""; _ia fresh
_R1="$MET2"$'\nUNCLEAR RQCNFG-1: open'; _ia
assert_contains "[IA6] the next call is shown the carried question" "$(_flat "$_P.1")" "$Q"
assert_contains "[IA6] ...and the answer forms" "$(_flat "$_P.1")" \
    "UNCLEAR <id>: answered | WHY: <how the issue answers it> | QUOTE: <the issue's words that answer it>"
assert_eq "[IA6] open: the question is kept" "$Q" "$(_res '(.data.unclear // [])[]')"
assert_eq "[IA6] ...and is no new finding" "" "$(_texts "$A/issue-acceptance-design-result.json")"
assert_eq "[IA6] ...the verdict is a pass" "pass" "$OUT"
_R1="$MET2"; _R2="$MET2"$'\nUNCLEAR RQCNFG-1: open'
rm -f "$A/issue-acceptance-judged.json"; _ia
assert_eq "[IA6] no answer line: asked again" "2" "$CALLS"
assert_contains "[IA6] ...naming it" "$(_flat "$_P.2")" "no line for UNCLEAR RQCNFG-1"
_R1="$MET2"$'\nUNCLEAR RQCNFG-1: answered | WHY: the issue says to exit | QUOTE: exit with an error'; _R2=""
rm -f "$A/issue-acceptance-judged.json"; _ia
assert_eq "[IA6] answered: the question is dropped" "" "$(_res '(.data.unclear // [])[]')"

print_test_section "IA7: a failed call keeps the questions"
_R1="$MET2"$'\n'"$Q"; _ia fresh
rm -f "$A/issue-acceptance-judged.json"; _RC=1; _ia; _RC=0
assert_eq "[IA7] the call failed: no pass" "no" "$([[ "$OUT" == pass ]] && echo yes || echo no)"
assert_eq "[IA7] ...and the result keeps the carried question" "$Q" "$(_res '(.data.unclear // [])[]')"

print_test_section "IA8: a question line never makes the answer unusable"
_notes() { jq -r '(.data.notes // [])[]' "$A/issue-acceptance-result.json" 2>/dev/null; }
_R1="$MET2"$'\n'"- $Q"; _R2=""; _ia fresh
assert_eq "[IA8] a question written as a list item is read: a pass" "pass" "$OUT"
assert_eq "[IA8] ...on the first answer" "1" "$CALLS"
assert_eq "[IA8] ...kept without its list mark" "$Q" "$(_res '(.data.unclear // [])[]')"
_R1="$MET2"$'\nUNCLEAR RQCNFG-1 | "Refuse a missing config file" | exit, or warn'; _R2=""; _ia fresh
assert_eq "[IA8] a new line still bad after the re-ask: asked once more, no more" "2" "$CALLS"
assert_eq "[IA8] ...the verdicts are kept: a pass" "pass" "$OUT"
assert_eq "[IA8] ...the line is left out" "" "$(_res '(.data.unclear // [])[]')"
assert_contains "[IA8] ...and the result notes it" "$(_notes)" "an UNCLEAR line was left out, still not in its form after it was asked again: UNCLEAR RQCNFG-1"
_R1="$MET2"$'\n'"$Q"; _R2=""; _ia fresh
_R1="$MET2"; _R2=""; rm -f "$A/issue-acceptance-judged.json"; _ia
assert_eq "[IA8] a carried question with no answer on either try: the verdicts are kept" "pass" "$OUT"
assert_eq "[IA8] ...the question is kept open" "$Q" "$(_res '(.data.unclear // [])[]')"
assert_contains "[IA8] ...and the result notes it" "$(_notes)" "UNCLEAR RQCNFG-1: no usable answer after it was asked again — kept open"
_R1="$MET2"$'\nUNCLEAR RQCNFG-1 | "Refuse a missing config file" | exit, or warn'; _R2=$'MET: RQFLAG-1'; _ia fresh
assert_eq "[IA8] a re-ask whose answer misses a verdict: the first answer's verdicts stand" "pass" "$OUT"
assert_eq "[IA8] ...after the one re-ask" "2" "$CALLS"

print_test_section "IA9: a retired question is recorded"
_R1="$MET2"$'\n'"$Q"; _R2=""; _ia fresh
_R1="$MET2"$'\nUNCLEAR RQCNFG-1: answered | WHY: the issue says to exit | QUOTE: exit with an error'
rm -f "$A/issue-acceptance-judged.json"; _ia
assert_eq "[IA9] recorded by its id" "RQCNFG-1" "$(_res '.data.unclear_dropped[0].id')"
assert_eq "[IA9] ...with how it was retired" "answered" "$(_res '.data.unclear_dropped[0].verdict')"
assert_eq "[IA9] ...its WHY" "the issue says to exit" "$(_res '.data.unclear_dropped[0].why')"
assert_eq "[IA9] ...its QUOTE" "exit with an error" "$(_res '.data.unclear_dropped[0].quote')"
assert_eq "[IA9] ...and the question it retired, as carried" "$Q" "$(_res '.data.unclear_dropped[0].question')"
_R1="$MET2"$'\n'"$Q"; _ia fresh
_R1="$MET2"$'\nUNCLEAR RQCNFG-1: not needed | WHY: the requirement is rewritten'
rm -f "$A/issue-acceptance-judged.json"; _ia
assert_eq "[IA9] not needed: recorded so" "not needed" "$(_res '.data.unclear_dropped[0].verdict')"
assert_eq "[IA9] ...with its WHY" "the requirement is rewritten" "$(_res '.data.unclear_dropped[0].why')"
_R1="$MET2"$'\nUNCLEAR RQCNFG-1: not needed | WHY: the requirement is rewritten'
rm -f "$A/issue-acceptance-judged.json"; _ia
assert_eq "[IA9] the next run carries nothing to drop: no record" "null" "$(_res '.data.unclear_dropped')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
