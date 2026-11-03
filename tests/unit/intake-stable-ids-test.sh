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
# S1  [code] a requirement's id is the one its REQUIREMENT line gives — a code
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
  {"id":"PRNT-1","text":"Print each line once."},
  {"id":"EXIT-1","text":"Keep the exit code."},
  {"id":"EXIT-2","text":"Exit 2 on a bad flag."}],
 "removed":[{"id":"PRNT-2","text":"Print in colour.","reason":"the issue dropped it"}]}'

# ── S1 ───────────────────────────────────────────────────────────────────────
_last ""
REPLY=([1]=$'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: EXIT-1 Keep the exit code.\nREQUIREMENT: CNT-1 Say how many lines it printed.')
_intake
assert_eq "[S1] each requirement keeps the id its line gives" "PRNT-1 EXIT-1 CNT-1" "$(_ids)"
assert_eq "[S1] ...and its words" "Keep the exit code." "$(jq -r '.requirements[1].text' "$_REQ" 2>/dev/null)"
assert_contains "[S1] the writing call is told what an id is" "$(_prompt 1)" "a dash, and a number"

# ── S2 / S3 ──────────────────────────────────────────────────────────────────
_last "$_L3"
REPLY=([1]=$'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: EXIT-1 Keep the exit code.\nREMOVED: EXIT-2 — the issue no longer asks for it\nREQUIREMENT: CNT-1 Say how many lines it printed.')
_intake
assert_contains "[S2] the last list is shown with its ids, in the REQUIREMENT form" "$(_prompt 1)" "REQUIREMENT: EXIT-2 Exit 2 on a bad flag."
assert_contains "[S2] ...with the ids already removed" "$(_prompt 1)" "PRNT-2"
assert_eq "[S3] kept ids stay; the new one is added" "PRNT-1 EXIT-1 CNT-1" "$(_ids)"
assert_eq "[S3] the dropped one is kept as removed, with its words and reason" \
    "EXIT-2|Exit 2 on a bad flag.|the issue no longer asks for it" \
    "$(jq -r '.removed[]? | select(.id == "EXIT-2") | "\(.id)|\(.text)|\(.reason)"' "$_REQ" 2>/dev/null)"
assert_eq "[S3] the result names what was added, by id" "CNT-1" \
    "$(jq -r '[.data.requirements_changed.added[]?.id] | join(" ")' "$RES" 2>/dev/null)"
assert_eq "[S3] ...and what was removed, with why" "EXIT-2 the issue no longer asks for it" \
    "$(jq -r '.data.requirements_changed.removed[]? | "\(.id) \(.reason)"' "$RES" 2>/dev/null)"
assert_contains "[S3] the summary names the addition" "$SUM" "added: CNT-1 Say how many lines it printed."
assert_contains "[S3] ...and the removal, with why" "$SUM" "removed: EXIT-2 Exit 2 on a bad flag. — the issue no longer asks for it"

# ── S4 ───────────────────────────────────────────────────────────────────────
_last "$_L3"
REPLY=([1]=$'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: EXIT-1 Keep the exit code.'
       [2]=$'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: EXIT-1 Keep the exit code.\nREMOVED: EXIT-2 — the issue no longer asks for it')
_intake
assert_contains "[S4] a dropped id with no REMOVED line is asked again, naming it" "$(_prompt 2)" "EXIT-2"
assert_contains "[S4] ...as a re-ask of the same call" "$(_prompt 2)" "could not be used"
assert_eq "[S4] answered right the second time, intake passes" "pass" "$OUTCOME"
_last "$_L3"
REPLY=([1]=$'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: EXIT-1 Keep the exit code.'
       [2]=$'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: EXIT-1 Keep the exit code.')
_intake
assert_eq "[S4] still wrong after one re-ask, intake ends unusable" "unusable" "$OUTCOME"

# ── S5 ───────────────────────────────────────────────────────────────────────
_last "$_L3"
REPLY=([1]=$'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: EXIT-1 Keep the exit code.\nREQUIREMENT: EXIT-2 Exit 2 on a bad flag.\nREQUIREMENT: PRNT-2 Print a count.'
       [2]=$'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: EXIT-1 Keep the exit code.\nREQUIREMENT: EXIT-2 Exit 2 on a bad flag.\nREQUIREMENT: PRNT-3 Print a count.')
_intake
assert_contains "[S5] a removed id coming back is refused, naming it" "$(_prompt 2)" "PRNT-2"
assert_eq "[S5] the next number after the code's highest is taken" "PRNT-1 EXIT-1 EXIT-2 PRNT-3" "$(_ids)"
_last '{"schema_version":1,"source":"model","requirements":[{"id":"PRNT-1","text":"a"},{"id":"PRNT-3","text":"b"}]}'
REPLY=([1]=$'REQUIREMENT: PRNT-1 a\nREQUIREMENT: PRNT-3 b\nREQUIREMENT: PRNT-2 c'
       [2]=$'REQUIREMENT: PRNT-1 a\nREQUIREMENT: PRNT-3 b\nREQUIREMENT: PRNT-2 c')
_intake
assert_contains "[S5] a new number below the code's highest is refused" "$(_prompt 2)" "PRNT-2"
assert_eq "[S5] ...and still wrong, intake ends unusable" "unusable" "$OUTCOME"
_last '{"schema_version":1,"source":"model","requirements":[{"id":"PRNT-1","text":"a"}]}'
REPLY=([1]=$'REQUIREMENT: PRNT-1 a\nREQUIREMENT: PRNT-3 b' [2]=$'REQUIREMENT: PRNT-1 a\nREQUIREMENT: PRNT-3 b')
_intake
assert_contains "[S5] a new number that skips one is refused (review #2463)" "$(_prompt 2)" "use PRNT-2"
assert_eq "[S5] ...and still wrong, intake ends unusable" "unusable" "$OUTCOME"
_last '{"schema_version":1,"source":"model","requirements":[{"id":"PRNT-1","text":"a"}]}'
REPLY=([1]=$'REQUIREMENT: PRNT-1 a\nREMOVED: FAKE-1 — made up' [2]=$'REQUIREMENT: PRNT-1 a\nREMOVED: FAKE-1 — made up')
_intake
assert_contains "[S3] a REMOVED line for an id the last list never had is refused (review #2463)" "$(_prompt 2)" "FAKE-1"
assert_eq "[S3] ...and still wrong, intake ends unusable" "unusable" "$OUTCOME"

# ── S6 ───────────────────────────────────────────────────────────────────────
_set_gh_mock "Make the gate quieter" $'KEEP-1: keep the exit code.\nPrint each line once.' 0
for _bad in $'REQUIREMENT: KEEP-1 Keep the exit code.' \
            $'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: PRNT-1 Keep the exit code.' \
            $'REQUIREMENT: R-1 Print each line once.' \
            $'REQUIREMENT: PRINTS-1 Print each line once.' \
            $'REQUIREMENT: Print each line once.'; do
    _last ""
    REPLY=([1]="$_bad" [2]="$_bad")
    _intake
    assert_eq "[S6] refused: ${_bad//$'\n'/ / }" "unusable" "$OUTCOME"
done
_last ""
REPLY=([1]=$'REQUIREMENT: PRNT-1 Print each line once.')
_intake
assert_eq "[S11] the ids the issue writes are recorded" "KEEP-1" "$(jq -r '[.issue_ids[]?] | join(" ")' "$_REQ" 2>/dev/null)"
_set_gh_mock "Make the gate quieter" $'1. Print each line once.\n2. Keep the exit code.\n3. Say how many lines it printed.' 0

# ── S7 ───────────────────────────────────────────────────────────────────────
_last "$_L3"
REPLY=([1]='- Print each line once.' [2]='- Print each line once.')
_intake
assert_eq "[S7] a try that cannot be used ends unusable" "unusable" "$OUTCOME"
REPLY=([1]=$'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: EXIT-1 Keep the exit code.\nREQUIREMENT: EXIT-2 Exit 2 on a bad flag.')
_intake
assert_contains "[S7] the next try is still shown the last list" "$(_prompt 1)" "REQUIREMENT: EXIT-2 Exit 2 on a bad flag."
assert_eq "[S7] ...and passes" "pass" "$OUTCOME"

# ── S8 ───────────────────────────────────────────────────────────────────────
assert_eq "[S8] an id removed in an earlier run stays removed" "PRNT-2" \
    "$(jq -r '[.removed[]?.id] | join(" ")' "$_REQ" 2>/dev/null)"

# ── S9 ───────────────────────────────────────────────────────────────────────
_last ""
REPLY=([1]=$'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: EXIT-1 Keep the exit code.'
       [2]='MISSING: CNT-1 Say how many lines it printed.')
_intake
assert_eq "[S9] the check's missing item is added with its id" "PRNT-1 EXIT-1 CNT-1" "$(_ids)"
assert_contains "[S9] the check call is shown the list with its ids" "$(_prompt 2)" "EXIT-1"
_last ""
REPLY=([1]=$'REQUIREMENT: PRNT-1 Print each line once.\nREQUIREMENT: EXIT-1 Keep the exit code.'
       [2]='MISSING: EXIT-1 Say how many lines it printed.' [3]='MISSING: EXIT-1 Say how many lines it printed.')
_intake
assert_contains "[S9] a missing item reusing a listed id is asked again" "$(_prompt 3)" "EXIT-1"
assert_eq "[S9] ...and still wrong, intake ends unusable" "unusable" "$OUTCOME"

# ── S10 ──────────────────────────────────────────────────────────────────────
_last '{"schema_version":1,"source":"model","requirements":[{"id":"R-1","text":"Print each line once."},{"id":"R-2","text":"Keep the exit code."}]}'
REPLY=([1]=$'REQUIREMENT: PRNT-1 Print each line once.')
_intake
assert_contains "[S10] an old position id is shown without its id" "$(_prompt 1)" "REQUIREMENT: Keep the exit code."
_lacks_r=1; [[ "$(_prompt 1)" == *"REQUIREMENT: R-2"* ]] && _lacks_r=0
assert_eq "[S10] ...never as R-2" "1" "$_lacks_r"
assert_eq "[S10] dropping it needs no REMOVED line" "pass" "$OUTCOME"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
