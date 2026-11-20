#!/usr/bin/env bash
# tests/unit/intake-unclear-test.sh — intake says what it finds unclear in the
# issue in the one form, and its own check judges every question it carried
# (#2571 R3, ADR-070 §1, ADR-069 §12).
#
# Why: intake paraphrased an unclear requirement silently, so nobody could see
# which reading the list went on with, and nothing ever asked again whether the
# issue had since settled it.
#
# IU1 [change] intake's writing call is told the one form and the rule
# IU2 [change] a good UNCLEAR line is kept in intake's result, data.unclear
# IU3 [change] a line with no ASSUMED, or whose quote is not in the issue, is
#              asked again with intake's re-ask, saying what is wrong
# IU4 [change] a line still bad after the re-ask does not stop the run: it is
#              left out, and intake's result notes it
# IU5 [change] the check is shown each carried question and the answer forms
# IU6 [change] answered (the issue's words quoted): the question is dropped from
#              intake's next result, and recorded there as its answer,
#              data.unclear_dropped, as every stage records one it retires
# IU7 [change] open: the question is kept; not needed: it is dropped, and
#              recorded
# IU8 [change] a carried question with no answer line is asked again, naming
#              it; still none: it is kept, never lost
# IU9 [change] an answer whose quote is not in the issue is asked again
# IU10 [change] an unchanged issue asks no model, and keeps the questions
# IU11 [change] a try whose requirement call fails keeps the questions in its
#              result, for the next try
# IU12 [change] a pass that writes no requirement list (the issue could not be
#              read, and a placeholder goal is allowed) keeps the questions
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "intake's unclear points, in the one form, judged by its check (#2571)"
setup_test_env "intake-unclear"
# shellcheck source=../../plugins/agent/intake/tests/intake-test-lib.sh
source "$REPO_ROOT/plugins/agent/intake/tests/intake-test-lib.sh"
set +e
_REQ="$ARTIFACT_DIR/requirements.json"
_RES="$ARTIFACT_DIR/intake-result.json"

# The writing call gets WRITE_REPLY, then WRITE_REPLY_2 on a re-ask; the check
# gets CHECK_REPLY, then CHECK_REPLY_2. A failing writer: WRITE_RC.
WRITE_REPLY=""; WRITE_REPLY_2=""; CHECK_REPLY=""; CHECK_REPLY_2=""; WRITE_RC=0
route_to_model() {
    local n w c; n=$(( $(cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/calls"
    printf '%s' "$2" > "$TEST_TEMP_DIR/prompt-$n"
    if [[ "$2" == *"check a list of requirements"* ]]; then
        c=$(( $(cat "$TEST_TEMP_DIR/checks" 2>/dev/null || echo 0) + 1 )); printf '%s' "$c" > "$TEST_TEMP_DIR/checks"
        printf '%s' "$2" > "$TEST_TEMP_DIR/check-$c"
        if (( c == 1 )); then printf '%s\n' "$CHECK_REPLY"; else printf '%s\n' "${CHECK_REPLY_2:-$CHECK_REPLY}"; fi
        return 0
    fi
    [[ "$WRITE_RC" -eq 0 ]] || return "$WRITE_RC"
    w=$(( $(cat "$TEST_TEMP_DIR/writes" 2>/dev/null || echo 0) + 1 )); printf '%s' "$w" > "$TEST_TEMP_DIR/writes"
    printf '%s' "$2" > "$TEST_TEMP_DIR/write-$w"
    if (( w == 1 )); then printf '%s\n' "$WRITE_REPLY"; else printf '%s\n' "${WRITE_REPLY_2:-$WRITE_REPLY}"; fi
    return 0
}
# _intake [keep] — one intake run; "keep" leaves the last list, so an unchanged
# issue is kept with no model call.
_intake() {
    [[ "${1:-}" == keep ]] || rm -f "$_REQ"
    rm -f "$TEST_TEMP_DIR"/calls "$TEST_TEMP_DIR"/checks "$TEST_TEMP_DIR"/writes \
        "$TEST_TEMP_DIR"/prompt-* "$TEST_TEMP_DIR"/check-* "$TEST_TEMP_DIR"/write-*
    unset ZBUILD_GOAL 2>/dev/null || true
    export ZBUILD_ISSUE="$_ZB_ID"
    intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$_RES" 2>/dev/null || echo MISSING)"
    CALLS="$(cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0)"
    WRITES="$(cat "$TEST_TEMP_DIR/writes" 2>/dev/null || echo 0)"
    CHECKS="$(cat "$TEST_TEMP_DIR/checks" 2>/dev/null || echo 0)"
}
_unclear() { jq -r '(.data.unclear // [])[]' "$_RES" 2>/dev/null; }
_notes() { jq -r '(.data.notes // [])[]' "$_RES" 2>/dev/null; }
_flat() { tr -s '[:space:]' ' ' < "$1" 2>/dev/null; }

BODY='## Required behavior

- **R1.** The report lists every open item.
- **R2.** Old items are dropped after a week.'
_set_gh_mock "Tidy the report" "$BODY" 0
REQS=$'REQUIREMENT: RQRPT-1 The report lists every open item.\nREQUIREMENT: RQAGE-1 Old items are dropped after a week.'
Q='UNCLEAR RQAGE-1 | "Old items are dropped after a week" | a week since opened, or a week since last updated | ASSUMED: a week since last updated'

# ── IU1 / IU2 ────────────────────────────────────────────────────────────────
print_test_section "IU1/IU2: raised in the one form, kept in the result"
WRITE_REPLY="$REQS"$'\n'"$Q"; CHECK_REPLY='MISSING: none'
_intake
assert_contains "[IU1] the writing call is told the one form" "$(_flat "$TEST_TEMP_DIR/write-1")" \
    "UNCLEAR <id> | \"<the issue's unclear words, quoted>\" | <the readings> | ASSUMED: <the reading chosen and acted on>"
assert_contains "[IU1] ...and to act on the reading it picks" "$(_flat "$TEST_TEMP_DIR/write-1")" "Pick one reading and act on it"
assert_eq "[IU2] intake passes" "pass" "$OUTCOME"
assert_eq "[IU2] the question is in intake's result, data.unclear, as written" "$Q" "$(_unclear)"
assert_eq "[IU2] ...on the first answer" "1" "$WRITES"

# ── IU3 / IU4 ────────────────────────────────────────────────────────────────
print_test_section "IU3/IU4: a bad line is asked again"
rm -f "$_RES"
WRITE_REPLY="$REQS"$'\nUNCLEAR RQAGE-1 | "Old items are dropped after a week" | opened, or last updated'
WRITE_REPLY_2="$REQS"$'\n'"$Q"
_intake
assert_eq "[IU3] a line with no ASSUMED is asked again" "2" "$WRITES"
assert_contains "[IU3] ...saying it has no ASSUMED" "$(_flat "$TEST_TEMP_DIR/write-2")" "has no ASSUMED"
assert_eq "[IU3] ...and the good line of the second answer is kept" "$Q" "$(_unclear)"

rm -f "$_RES"
WRITE_REPLY="$REQS"$'\nUNCLEAR RQAGE-1 | "Stale items vanish" | opened, or last updated | ASSUMED: last updated'
WRITE_REPLY_2="$REQS"$'\n'"$Q"
_intake
assert_eq "[IU3] a quote not in the issue is asked again" "2" "$WRITES"
assert_contains "[IU3] ...saying the words are not the issue's" "$(_flat "$TEST_TEMP_DIR/write-2")" "quotes words that are not in the issue: Stale items vanish"

rm -f "$_RES"
WRITE_REPLY="$REQS"$'\nUNCLEAR RQAGE-1 | "Stale items vanish" | opened, or last updated | ASSUMED: last updated'
WRITE_REPLY_2=""
_intake
assert_eq "[IU4] still bad after the re-ask: the run is not stopped" "pass" "$OUTCOME"
assert_eq "[IU4] ...the line is left out of data.unclear" "" "$(_unclear)"
assert_contains "[IU4] ...and intake's result notes it" "$(_notes)" "Stale items vanish"

# ── IU5 / IU6 ────────────────────────────────────────────────────────────────
print_test_section "IU5/IU6: a carried question the issue now answers"
rm -f "$_RES"; WRITE_REPLY="$REQS"$'\n'"$Q"; WRITE_REPLY_2=""; CHECK_REPLY='MISSING: none'; CHECK_REPLY_2=""
_intake
BODY2="$BODY"'

## Terms
- **Old item:** an item not updated for a week.'
_set_gh_mock "Tidy the report" "$BODY2" 0
WRITE_REPLY="$REQS"
CHECK_REPLY=$'MISSING: none\nUNCLEAR RQAGE-1: answered | WHY: the Terms say an old item is one not updated for a week | QUOTE: an item not updated for a week'
_intake
assert_contains "[IU5] the check is shown the carried question" "$(_flat "$TEST_TEMP_DIR/check-1")" "$Q"
assert_contains "[IU5] ...and the answer forms" "$(_flat "$TEST_TEMP_DIR/check-1")" \
    "UNCLEAR <id>: answered | WHY: <how the issue answers it> | QUOTE: <the issue's words that answer it>"
assert_eq "[IU6] intake passes" "pass" "$OUTCOME"
assert_eq "[IU6] the answered question is dropped from intake's result" "" "$(_unclear)"
_dres() { jq -r "$1" "$_RES" 2>/dev/null || echo MISSING; }
assert_eq "[IU6] recorded by its id" "RQAGE-1" "$(_dres '.data.unclear_dropped[0].id')"
assert_eq "[IU6] ...with how it was retired" "answered" "$(_dres '.data.unclear_dropped[0].verdict')"
assert_eq "[IU6] ...its WHY" "the Terms say an old item is one not updated for a week" "$(_dres '.data.unclear_dropped[0].why')"
assert_eq "[IU6] ...its QUOTE" "an item not updated for a week" "$(_dres '.data.unclear_dropped[0].quote')"
assert_eq "[IU6] ...and the question it retired, as carried" "$Q" "$(_dres '.data.unclear_dropped[0].question')"
assert_eq "[IU6] ...once: not again in its notes" "" "$(_notes | grep -F 'RQAGE-1' || true)"

# ── IU7 ──────────────────────────────────────────────────────────────────────
print_test_section "IU7: open is kept, not needed is dropped"
_set_gh_mock "Tidy the report" "$BODY" 0
rm -f "$_RES"; WRITE_REPLY="$REQS"$'\n'"$Q"; CHECK_REPLY='MISSING: none'
_intake
_set_gh_mock "Tidy the report" "$BODY"$'\n- **R3.** The report is sorted.' 0
WRITE_REPLY="$REQS"$'\nREQUIREMENT: RQSRT-1 The report is sorted.'
CHECK_REPLY=$'MISSING: none\nUNCLEAR RQAGE-1: open'
_intake
assert_eq "[IU7] open: the question stays in intake's result" "$Q" "$(_unclear)"
assert_eq "[IU7] ...asked once" "1" "$CHECKS"
_set_gh_mock "Tidy the report" '- **R1.** The report lists every open item.' 0
WRITE_REPLY='REQUIREMENT: RQRPT-1 The report lists every open item.'
CHECK_REPLY=$'MISSING: none\nUNCLEAR RQAGE-1: not needed | WHY: the requirement about old items is gone from the issue'
_intake
assert_eq "[IU7] not needed: the question is dropped" "" "$(_unclear)"
assert_eq "[IU7] ...and recorded so" "not needed" "$(_dres '.data.unclear_dropped[0].verdict')"
assert_eq "[IU7] ...with its WHY" "the requirement about old items is gone from the issue" "$(_dres '.data.unclear_dropped[0].why')"

# ── IU8 / IU9 ────────────────────────────────────────────────────────────────
print_test_section "IU8/IU9: no answer, or a bad one, is asked again"
_set_gh_mock "Tidy the report" "$BODY" 0
rm -f "$_RES"; WRITE_REPLY="$REQS"$'\n'"$Q"; CHECK_REPLY='MISSING: none'; CHECK_REPLY_2=""
_intake
_set_gh_mock "Tidy the report" "$BODY2" 0
WRITE_REPLY="$REQS"; CHECK_REPLY='MISSING: none'
CHECK_REPLY_2=$'MISSING: none\nUNCLEAR RQAGE-1: open'
_intake
assert_eq "[IU8] a question with no answer line is asked again" "2" "$CHECKS"
assert_contains "[IU8] ...naming it" "$(_flat "$TEST_TEMP_DIR/check-2")" "no line for UNCLEAR RQAGE-1"
assert_eq "[IU8] ...and kept when it is open" "$Q" "$(_unclear)"
_set_gh_mock "Tidy the report" "$BODY" 0
CHECK_REPLY='MISSING: none'; CHECK_REPLY_2=""
_intake
assert_eq "[IU8] no line on either answer: the run is not stopped" "pass" "$OUTCOME"
assert_eq "[IU8] ...and the question is kept, never lost" "$Q" "$(_unclear)"

_set_gh_mock "Tidy the report" "$BODY2" 0
CHECK_REPLY=$'MISSING: none\nUNCLEAR RQAGE-1: answered | WHY: it says so | QUOTE: items expire on Sundays'
CHECK_REPLY_2=$'MISSING: none\nUNCLEAR RQAGE-1: open'
_intake
assert_eq "[IU9] an answer whose quote is not in the issue is asked again" "2" "$CHECKS"
assert_contains "[IU9] ...saying so" "$(_flat "$TEST_TEMP_DIR/check-2")" "UNCLEAR RQAGE-1's quote is not in the issue"
assert_eq "[IU9] ...and the question is not dropped on it" "$Q" "$(_unclear)"

# ── IU10 / IU11 ──────────────────────────────────────────────────────────────
print_test_section "IU10/IU11: an unchanged issue, and a failed try"
_intake keep
assert_eq "[IU10] an unchanged issue asks no model" "0" "$CALLS"
assert_eq "[IU10] ...and keeps the question" "$Q" "$(_unclear)"
_set_gh_mock "Tidy the report" "$BODY"$'\n- **R4.** Something new.' 0
WRITE_RC=1
_intake
assert_eq "[IU11] the requirement call fails: intake does not pass" "not pass" "$([[ "$OUTCOME" == pass || "$OUTCOME" == MISSING ]] && echo "$OUTCOME" || echo 'not pass')"
assert_eq "[IU11] ...and its result keeps the question for the next try" "$Q" "$(_unclear)"
WRITE_RC=0

_set_gh_mock "Tidy the report" "$BODY" 0
rm -f "$_RES"; WRITE_REPLY="$REQS"$'\n'"$Q"; CHECK_REPLY='MISSING: none'; CHECK_REPLY_2=""
_intake
_set_gh_mock "Tidy the report" "$BODY" 1
export ZBUILD_INTAKE_ALLOW_PLACEHOLDER=1
_intake
unset ZBUILD_INTAKE_ALLOW_PLACEHOLDER
assert_eq "[IU12] the issue could not be read: a placeholder pass" "pass" "$OUTCOME"
assert_eq "[IU12] ...which keeps the question for the next try" "$Q" "$(_unclear)"
_set_gh_mock "Tidy the report" "$BODY" 0

cleanup_test_env
print_test_results
exit $((FAIL > 0))
