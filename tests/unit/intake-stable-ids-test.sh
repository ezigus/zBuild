#!/usr/bin/env bash
# tests/unit/intake-stable-ids-test.sh — each requirement's id describes it and
# never moves; a dropped one says why (#2462, ADR-070 §1, §2).
#
# Why: ids were R-<position>. On #1805 run 41582195372 intake's second try wrote
# 14 requirements instead of 16, in a new order, so every R-n pointed at a
# different requirement than design's kept work named, and design spent three
# tries on numbering alone. Try 2 never saw the last list at all: intake deleted
# it at the start of try 1, which then failed. Try 1 had been shown the last
# list as bullets, and answered in bullets.
#
# S1  [code] a requirement's id is the one its REQUIREMENT line gives — RQ, a code
#            describing it, a dash and a number — never its position
# S2  [code] the last list is shown with its ids, in the REQUIREMENT form the
#            reply is written in, with the ids already removed
# S3  [code] a kept id stays; a dropped one answered `REMOVED: <id> — <why>` is
#            kept as removed with its words and reason, and the summary and
#            result list what was added and removed, by id, with the reason
# S4  [code] a dropped id with no REMOVED line is asked again once, naming it;
#            asked again and still wrong, intake ends unusable
# S5  [code] a new id's number is one more than its code's highest, removed
#            ones counted: a removed id never comes back, and a lower number is
#            refused
# S6  [code] an id the issue's own text writes, a duplicate, and a bad form are
#            refused
# S7  [code] a try after a failed try is still shown the last list
# S8  [code] removed ids are carried on to the next run's list
# S9  [code] the check call's missing items carry ids, held to the same rules
# S10 [code] a last list with old position ids is shown without them: those
#            requirements get new ids, and need no REMOVED line
# S11 [code] the list records the ids the issue's own text writes, so design
#            can refuse them as SPEC ids without reading the issue again
# S12 [code] #2482: every requirement id starts with intake's prefix, RQ; one
#            without it is asked again; a requirement may share a SPEC's code;
#            a last-list id from before the prefix is the old numbering
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "requirement ids describe their item and never move (#2462)"
setup_test_env "intake-stable-ids"
# shellcheck source=../../plugins/agent/intake/tests/intake-test-lib.sh
source "$REPO_ROOT/plugins/agent/intake/tests/intake-test-lib.sh"
set +e
_REQ="$ARTIFACT_DIR/requirements.json"

# The model: the n-th call answers REPLY[n]; an unset one answers "MISSING: none".
declare -a REPLY=()
route_to_model() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/calls"
    printf '%s' "$2" > "$TEST_TEMP_DIR/prompt-$n"
    printf '%s\n' "${REPLY[$n]:-MISSING: none}"
    return 0
}
_last() {   # the list a last run left: <json>
    if [[ -z "${1:-}" ]]; then rm -f "$_REQ"; else printf '%s\n' "$1" > "$_REQ"; fi
}
_intake() {
    rm -f "$TEST_TEMP_DIR"/calls "$TEST_TEMP_DIR"/prompt-*
    unset ZBUILD_GOAL 2>/dev/null || true
    export ZBUILD_ISSUE="$_ZB_ID"
    intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
    RES="$ARTIFACT_DIR/intake-result.json"; SUM="$(cat "$ARTIFACT_DIR/intake-summary.md" 2>/dev/null)"
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$RES" 2>/dev/null || echo MISSING)"
    CALLS="$(cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0)"
}
_ids() { jq -r '[.requirements[]?.id] | join(" ")' "$_REQ" 2>/dev/null; }
_prompt() { tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/prompt-$1" 2>/dev/null; }

_set_gh_mock "Make the gate quieter" $'1. Print each line once.\n2. Keep the exit code.\n3. Say how many lines it printed.' 0

_L3='{"schema_version":1,"source":"model","requirements":[
  {"id":"RQPRNT-1","text":"Print each line once."},
  {"id":"RQEXIT-1","text":"Keep the exit code."},
  {"id":"RQEXIT-2","text":"Exit 2 on a bad flag."}],
 "removed":[{"id":"RQPRNT-2","text":"Print in colour.","reason":"the issue dropped it"}]}'

# ── S1 ───────────────────────────────────────────────────────────────────────
_last ""
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.\nREQUIREMENT: RQCNT-1 Say how many lines it printed.')
_intake
assert_eq "[S1] each requirement keeps the id its line gives" "RQPRNT-1 RQEXIT-1 RQCNT-1" "$(_ids)"
assert_eq "[S1] ...and its words" "Keep the exit code." "$(jq -r '.requirements[1].text' "$_REQ" 2>/dev/null)"
assert_contains "[S1] the writing call is told what an id is" "$(_prompt 1)" "a dash, and a number"

# ── S2 / S3 ──────────────────────────────────────────────────────────────────
_last "$_L3"
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.\nREMOVED: RQEXIT-2 — the issue no longer asks for it\nREQUIREMENT: RQCNT-1 Say how many lines it printed.')
_intake
assert_contains "[S2] the last list is shown with its ids, in the REQUIREMENT form" "$(_prompt 1)" "REQUIREMENT: RQEXIT-2 Exit 2 on a bad flag."
assert_contains "[S2] ...with the ids already removed" "$(_prompt 1)" "RQPRNT-2"
assert_eq "[S3] kept ids stay; the new one is added" "RQPRNT-1 RQEXIT-1 RQCNT-1" "$(_ids)"
assert_eq "[S3] the dropped one is kept as removed, with its words and reason" \
    "RQEXIT-2|Exit 2 on a bad flag.|the issue no longer asks for it" \
    "$(jq -r '.removed[]? | select(.id == "RQEXIT-2") | "\(.id)|\(.text)|\(.reason)"' "$_REQ" 2>/dev/null)"
assert_eq "[S3] the result names what was added, by id" "RQCNT-1" \
    "$(jq -r '[.data.requirements_changed.added[]?.id] | join(" ")' "$RES" 2>/dev/null)"
assert_eq "[S3] ...and what was removed, with why" "RQEXIT-2 the issue no longer asks for it" \
    "$(jq -r '.data.requirements_changed.removed[]? | "\(.id) \(.reason)"' "$RES" 2>/dev/null)"
assert_contains "[S3] the summary names the addition" "$SUM" "added: RQCNT-1 Say how many lines it printed."
assert_contains "[S3] ...and the removal, with why" "$SUM" "removed: RQEXIT-2 Exit 2 on a bad flag. — the issue no longer asks for it"

# ── S4 ───────────────────────────────────────────────────────────────────────
_last "$_L3"
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.'
       [2]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.\nREMOVED: RQEXIT-2 — the issue no longer asks for it')
_intake
assert_contains "[S4] a dropped id with no REMOVED line is asked again, naming it" "$(_prompt 2)" "RQEXIT-2"
assert_contains "[S4] ...as a re-ask of the same call" "$(_prompt 2)" "could not be used"
assert_eq "[S4] answered right the second time, intake passes" "pass" "$OUTCOME"
_last "$_L3"
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.'
       [2]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.')
_intake
assert_eq "[S4] still wrong after one re-ask, intake ends unusable" "unusable" "$OUTCOME"

# ── S5 ───────────────────────────────────────────────────────────────────────
_last "$_L3"
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.\nREQUIREMENT: RQEXIT-2 Exit 2 on a bad flag.\nREQUIREMENT: RQPRNT-2 Print a count.'
       [2]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.\nREQUIREMENT: RQEXIT-2 Exit 2 on a bad flag.\nREQUIREMENT: RQPRNT-3 Print a count.')
_intake
assert_contains "[S5] a removed id coming back is refused, naming it" "$(_prompt 2)" "RQPRNT-2"
assert_eq "[S5] the next number after the code's highest is taken" "RQPRNT-1 RQEXIT-1 RQEXIT-2 RQPRNT-3" "$(_ids)"
_last '{"schema_version":1,"source":"model","requirements":[{"id":"RQPRNT-1","text":"a"},{"id":"RQPRNT-3","text":"b"}]}'
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 a\nREQUIREMENT: RQPRNT-3 b\nREQUIREMENT: RQPRNT-2 c'
       [2]=$'REQUIREMENT: RQPRNT-1 a\nREQUIREMENT: RQPRNT-3 b\nREQUIREMENT: RQPRNT-2 c')
_intake
assert_contains "[S5] a new number below the code's highest is refused" "$(_prompt 2)" "RQPRNT-2"
assert_eq "[S5] ...and still wrong, intake ends unusable" "unusable" "$OUTCOME"
_last '{"schema_version":1,"source":"model","requirements":[{"id":"RQPRNT-1","text":"a"}]}'
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 a\nREQUIREMENT: RQPRNT-3 b' [2]=$'REQUIREMENT: RQPRNT-1 a\nREQUIREMENT: RQPRNT-3 b')
_intake
assert_contains "[S5] a new number that skips one is refused (review #2463)" "$(_prompt 2)" "use RQPRNT-2"
assert_eq "[S5] ...and still wrong, intake ends unusable" "unusable" "$OUTCOME"
_last '{"schema_version":1,"source":"model","requirements":[{"id":"RQPRNT-1","text":"a"}]}'
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 a\nREMOVED: RQFAKE-1 — made up' [2]=$'REQUIREMENT: RQPRNT-1 a\nREMOVED: RQFAKE-1 — made up')
_intake
assert_contains "[S3] a REMOVED line for an id the last list never had is refused (review #2463)" "$(_prompt 2)" "RQFAKE-1"
assert_eq "[S3] ...and still wrong, intake ends unusable" "unusable" "$OUTCOME"

# ── S6 ───────────────────────────────────────────────────────────────────────
_set_gh_mock "Make the gate quieter" $'RQKEEP-1: keep the exit code.\nPrint each line once.' 0
for _bad in $'REQUIREMENT: RQKEEP-1 Keep the exit code.' \
            $'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQPRNT-1 Keep the exit code.' \
            $'REQUIREMENT: R-1 Print each line once.' \
            $'REQUIREMENT: PRINTS-1 Print each line once.' \
            $'REQUIREMENT: Print each line once.'; do
    _last ""
    REPLY=([1]="$_bad" [2]="$_bad")
    _intake
    assert_eq "[S6] refused: ${_bad//$'\n'/ / }" "unusable" "$OUTCOME"
done
_last ""
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.')
_intake
assert_eq "[S11] the ids the issue writes are recorded" "RQKEEP-1" "$(jq -r '[.issue_ids[]?] | join(" ")' "$_REQ" 2>/dev/null)"
_set_gh_mock "Make the gate quieter" $'1. Print each line once.\n2. Keep the exit code.\n3. Say how many lines it printed.' 0

# ── S7 ───────────────────────────────────────────────────────────────────────
_last "$_L3"
REPLY=([1]='- Print each line once.' [2]='- Print each line once.')
_intake
assert_eq "[S7] a try that cannot be used ends unusable" "unusable" "$OUTCOME"
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.\nREQUIREMENT: RQEXIT-2 Exit 2 on a bad flag.')
_intake
assert_contains "[S7] the next try is still shown the last list" "$(_prompt 1)" "REQUIREMENT: RQEXIT-2 Exit 2 on a bad flag."
assert_eq "[S7] ...and passes" "pass" "$OUTCOME"

# ── S8 ───────────────────────────────────────────────────────────────────────
assert_eq "[S8] an id removed in an earlier run stays removed" "RQPRNT-2" \
    "$(jq -r '[.removed[]?.id] | join(" ")' "$_REQ" 2>/dev/null)"

# ── S9 ───────────────────────────────────────────────────────────────────────
_last ""
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.'
       [2]='MISSING: RQCNT-1 Say how many lines it printed.')
_intake
assert_eq "[S9] the check's missing item is added with its id" "RQPRNT-1 RQEXIT-1 RQCNT-1" "$(_ids)"
assert_contains "[S9] the check call is shown the list with its ids" "$(_prompt 2)" "RQEXIT-1"
_last ""
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.'
       [2]='MISSING: RQEXIT-1 Say how many lines it printed.' [3]='MISSING: RQEXIT-1 Say how many lines it printed.')
_intake
assert_contains "[S9] a missing item reusing a listed id is asked again" "$(_prompt 3)" "RQEXIT-1"
assert_eq "[S9] ...and still wrong, intake ends unusable" "unusable" "$OUTCOME"

# ── S10 ──────────────────────────────────────────────────────────────────────
_last '{"schema_version":1,"source":"model","requirements":[{"id":"R-1","text":"Print each line once."},{"id":"R-2","text":"Keep the exit code."}]}'
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.')
_intake
assert_contains "[S10] an old position id is shown without its id" "$(_prompt 1)" "REQUIREMENT: Keep the exit code."
_lacks_r=1; [[ "$(_prompt 1)" == *"REQUIREMENT: R-2"* ]] && _lacks_r=0
assert_eq "[S10] ...never as R-2" "1" "$_lacks_r"
assert_eq "[S10] dropping it needs no REMOVED line" "pass" "$OUTCOME"

# ── S12 ──────────────────────────────────────────────────────────────────────
# #2482: every requirement id starts with intake's prefix, RQ, so a requirement
# and a SPEC never share an id — on #1805 run 42293991602 the rule that kept
# their codes apart told design two things that could not both hold.
_last ""
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: DISP-1 Dispatch the stage.'
       [2]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQDISP-1 Dispatch the stage.')
_intake
assert_contains "[S12] a requirement id without RQ is asked again, naming the prefix" "$(_prompt 2)" "DISP-1 does not start with RQ"
assert_eq "[S12] ...and with it, it passes" "RQPRNT-1 RQDISP-1" "$(_ids)"
assert_contains "[S12] the writing call is told the prefix" "$(_prompt 1)" "RQLOOP-1"
printf '# Design\n```acceptance\nDSDISP-1[code]: the stage is dispatched covers: RQPRNT-1\nWIRING: none\nTESTFILES:\nDSDISP-1: tests/d-test.sh\n```\n' \
    > "$ARTIFACT_DIR/design.md"
_last ""
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQDISP-1 Dispatch the stage.')
_intake
assert_eq "[S12] a requirement may share a SPEC's code: the prefixes keep them apart" "pass" "$OUTCOME"
rm -f "$ARTIFACT_DIR/design.md"
# The last list's ids from before the prefix are the old numbering: shown
# without them, given new ones, and needing no REMOVED line.
_last '{"schema_version":1,"source":"model","requirements":[{"id":"PRNT-1","text":"Print each line once."},{"id":"EXIT-1","text":"Keep the exit code."}],"removed":[{"id":"GONE-1","text":"x","reason":"y"}]}'
REPLY=([1]=$'REQUIREMENT: RQPRNT-1 Print each line once.\nREQUIREMENT: RQEXIT-1 Keep the exit code.')
_intake
assert_contains "[S12] a last-list id from before the prefix is shown without it" "$(_prompt 1)" "REQUIREMENT: Keep the exit code."
assert_eq "[S12] ...and its new id needs no REMOVED line" "pass" "$OUTCOME"
cleanup_test_env
print_test_results
exit $((FAIL > 0))
