#!/usr/bin/env bash
# tests/unit/intake-missing-quote-test.sh — a requirement intake's check says
# the list misses is written in the issue's words, and checked (#2569 R6,
# ADR-070 §1).
#
# Why: on #1764 run 44530053809 the check found the new R6 missing and wrote it
# as four paraphrased pieces ("The coordinator's claim hook adds the
# `zbuild:claimed` label", …). R6's main point — the engine claims and releases
# only through the coordinator's hooks, called through the plugin registry —
# was in none of them, and nothing checked the "in the issue's words" rule.
#
# "In the issue's words" means: whole sentences of the issue, copied as written
# (spacing and the marks `*`, `_`, backticks and quote marks aside; a stop at
# the end may be left off). A line the issue writes as a list item starts its
# sentence after the bullet and the item's own label ("- **R6.** ").
#
# M1 [change] a paraphrased MISSING line is refused and asked again once, with
#             the reason; the whole R6 item on the second answer is kept
# M2 [change] the whole R6 item (two sentences, backticks dropped) passes on
#             the first answer: no re-ask
# M3 [change] a part of a sentence — the run's "the label calls … are in …" and
#             "Nothing under `core/` calls `gh` for the label" — is refused
# M4 [change] a paraphrase on both answers does not stop the run: the line is
#             kept, and intake's result notes it is not in the issue's words
# M5 [guard]  a MISSING line that writes the list's ids for the issue's own item
#             names (as the check is told to) passes when its other words are
#             the issue's
# M7 [change] the check is told what the issue's words are: whole sentences,
#             never a paraphrase or a part of one
# M6 [guard]  a LIMIT line ("Do not …", which the issue may not write) is not
#             held to the issue's words
# M8 [change] a sentence the issue hard-wraps over two lines is one sentence:
#             the whole of it passes; the part after its colon does not
# M9 [change] a list item's sub-bullets are part of the item: the item with its
#             sub-points passes, written with or without their marks; the
#             lead-in alone is a part of the item
# M10 [change] #1764's R6, hard-wrapped inside its list item, passes on the
#             first answer
# M11 [change] a line with the list's ids is still whole sentences of the
#             issue: its words between the ids are held to one sentence, in
#             order ("RQCLM-1 and RQCLM-2 the check with that finding" fails)
# M12 [change] the issue is made ready for the comparison once a call, not
#             once a MISSING line (a 195 KB issue took seconds a line)
# M13 [guard]  the reviewer's cases (#2569 review): whole sentences pass;
#             parts, paraphrases and ids the issue does not write do not
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "intake's MISSING line is in the issue's words (#2569)"
setup_test_env "intake-missing-quote"
# shellcheck source=../../plugins/agent/intake/tests/intake-test-lib.sh
source "$REPO_ROOT/plugins/agent/intake/tests/intake-test-lib.sh"
set +e
_REQ="$ARTIFACT_DIR/requirements.json"

# Call 1 writes the list; calls 2 and 3 are the check and its one re-ask.
WRITE_REPLY=""; CHECK_REPLY=""; CHECK_REPLY_2=""
route_to_model() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/calls"
    printf '%s' "$2" > "$TEST_TEMP_DIR/prompt-$n"
    case "$n" in
        1) printf '%s\n' "$WRITE_REPLY" ;;
        2) printf '%s\n' "$CHECK_REPLY" ;;
        *) printf '%s\n' "${CHECK_REPLY_2:-$CHECK_REPLY}" ;;
    esac
    return 0
}
_intake() {
    rm -f "$_REQ" "$TEST_TEMP_DIR"/calls "$TEST_TEMP_DIR"/prompt-*
    unset ZBUILD_GOAL 2>/dev/null || true
    export ZBUILD_ISSUE="$_ZB_ID"
    intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$ARTIFACT_DIR/intake-result.json" 2>/dev/null || echo MISSING)"
    CALLS="$(cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0)"
}
_texts() { jq -r '[.requirements[].text] | join("\n")' "$_REQ" 2>/dev/null || echo MISSING; }
_notes() { jq -r '(.data.notes // [])[]' "$ARTIFACT_DIR/intake-result.json" 2>/dev/null; }

# R5 and R6 as #1764 writes them.
_R6_1='The engine claims and releases only through the claim coordinator'"'"'s `claim` and `release` hooks, called through the plugin registry; the label calls (`gh issue edit`) are in `plugins/claim-coordinator/github-labels/`, and nothing under `core/` calls `gh` for the label.'
_R6_2='A test that registers a stub claim coordinator sees its `claim` hook called before the first stage and its `release` hook called on exit.'
_body="## Required behavior

- **R5.** A local run and a CI run use the same label, \`zbuild:claimed\`. There is no machine name in the label.
- **R6.** $_R6_1 $_R6_2
- **R7.** Tests cover R5 and R6."
_set_gh_mock "Claim an issue across machines" "$_body" 0
WRITE_REPLY='REQUIREMENT: RQLBL-1 A local run and a CI run use the same label, `zbuild:claimed`. There is no machine name in the label.'

# ── M1 ───────────────────────────────────────────────────────────────────────
CHECK_REPLY='MISSING: RQCLM-1 The coordinator'"'"'s claim hook adds the `zbuild:claimed` label'
CHECK_REPLY_2="MISSING: RQCLM-1 $_R6_1 $_R6_2"
_intake
assert_eq "[M1] the paraphrase is asked again once" "3" "$CALLS"
_p3="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/prompt-3" 2>/dev/null)"
assert_contains "[M1] ...saying it is not in the issue's words" "$_p3" "RQCLM-1 is not in the issue's words"
assert_eq "[M1] the whole R6 on the second answer: intake passes" "pass" "$OUTCOME"
assert_contains "[M1] ...and R6's main point is in the list" "$(_texts)" "called through the plugin registry"

_p2="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/prompt-2" 2>/dev/null)"
assert_contains "[M7] the check is told the issue's words are whole sentences" "$_p2" \
    "The issue's words are its own sentences, copied as written: the whole sentence or item, never a paraphrase and never a part of a sentence."

# ── M2 ───────────────────────────────────────────────────────────────────────
CHECK_REPLY="MISSING: RQCLM-1 ${_R6_1//\`/} ${_R6_2//\`/}"; CHECK_REPLY_2=""
_intake
assert_eq "[M2] the whole R6 item passes" "pass" "$OUTCOME"
assert_eq "[M2] ...on the first answer" "2" "$CALLS"

# ── M3 ───────────────────────────────────────────────────────────────────────
CHECK_REPLY='MISSING: RQCLM-1 The label calls (`gh issue edit`) are in `plugins/claim-coordinator/github-labels/`'
CHECK_REPLY_2="MISSING: RQCLM-1 $_R6_1"
_intake
assert_eq "[M3] a part of a sentence is asked again" "3" "$CALLS"
assert_contains "[M3] ...saying so" "$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/prompt-3" 2>/dev/null)" "RQCLM-1 is not in the issue's words"
assert_eq "[M3] one whole sentence of the item passes" "pass" "$OUTCOME"
CHECK_REPLY='MISSING: RQCLM-1 Nothing under `core/` calls `gh` for the label'
CHECK_REPLY_2=""
_intake
assert_eq "[M3] the run's \"Nothing under core/ …\" piece is asked again" "3" "$CALLS"
assert_contains "[M3] ...and, still a part, is noted as not in the issue's words" "$(_notes)" "RQCLM-1 is not in the issue's words"

# ── M4 ───────────────────────────────────────────────────────────────────────
CHECK_REPLY='MISSING: RQCLM-1 The coordinator'"'"'s claim hook adds the `zbuild:claimed` label'
CHECK_REPLY_2=""
_intake
assert_eq "[M4] a paraphrase on both answers does not stop the run" "pass" "$OUTCOME"
assert_contains "[M4] ...the line is kept in the list" "$(_texts)" "The coordinator's claim hook adds the"
assert_contains "[M4] ...and intake's result names it as not in the issue's words" "$(_notes)" \
    "RQCLM-1 is not in the issue's words: \"The coordinator's claim hook adds the \`zbuild:claimed\` label\""
assert_contains "[M4] ...so does intake's summary" "$(cat "$ARTIFACT_DIR/intake-summary.md" 2>/dev/null)" "RQCLM-1 is not in the issue's words"
CHECK_REPLY="MISSING: RQCLM-1 $_R6_1"
_intake
assert_eq "[M4] a line in the issue's words leaves no note" "" "$(_notes)"

# ── M5 ───────────────────────────────────────────────────────────────────────
CHECK_REPLY="MISSING: RQCLM-1 $_R6_1
MISSING: RQTST-1 Tests cover RQLBL-1 and RQCLM-1."
CHECK_REPLY_2=""
_intake
assert_eq "[M5] the list's ids in place of the issue's item names pass" "pass" "$OUTCOME"
assert_eq "[M5] ...on the first answer" "2" "$CALLS"

# ── M6 ───────────────────────────────────────────────────────────────────────
CHECK_REPLY='LIMIT: LMNMC-1 Do not put a machine name in the label'
_intake
assert_eq "[M6] a limit's \"Do not\" line is not held to the issue's words" "pass" "$OUTCOME"
assert_eq "[M6] ...on the first answer" "2" "$CALLS"

# ── M8–M13: the comparison itself ────────────────────────────────────────────
# _in <name> <expect: in|out> <text> <issue>
_in() {
    local got=out
    _ireq_in_issue "$3" "$4" && got=in
    assert_eq "$1" "$2" "$got"
}
_wrapped=$'A plain paragraph that the author wrapped by hand: intake\'s MISSING line is refused unless its\ntext is in the issue. Then more.'
_in "[M8] a hard-wrapped sentence, whole, is the issue's words" in \
    "A plain paragraph that the author wrapped by hand: intake's MISSING line is refused unless its text is in the issue." "$_wrapped"
_in "[M8] ...the part after its colon is not" out \
    "intake's MISSING line is refused unless its text is in the issue." "$_wrapped"
_in "[M8] ...nor is its first line alone" out \
    "A plain paragraph that the author wrapped by hand: intake's MISSING line is refused unless its" "$_wrapped"

_rev=$'## Required behavior\n\n- **R1.** A part a check refused in an earlier try is shown to the check with that finding and the stage\'s answer. #1764\'s case is judged.\n- **R2.** Every check\'s refusal carries ACCEPTED IF:\n  - design\'s check\n  - the lenses\n- **R3.** The command `zbuild run --issue N` must print the run id (e.g. 42).\n\n1. Intake keeps it whole.'
_in "[M9] the item with its sub-points, as a list in one line" in "Every check's refusal carries ACCEPTED IF: design's check, the lenses" "$_rev"
_in "[M9] ...with the sub-bullets' marks" in "Every check's refusal carries ACCEPTED IF: - design's check - the lenses" "$_rev"
_in "[M9] ...the lead-in alone is a part of the item" out "Every check's refusal carries ACCEPTED IF" "$_rev"
_in "[M9] ...a sub-point alone is a part of the item" out "the lenses" "$_rev"

# M10: #1764's R6 as a person hard-wraps it in the item.
_body="## Required behavior

- **R5.** A local run and a CI run use the same label, \`zbuild:claimed\`. There is no machine name in the label.
- **R6.** The engine claims and releases only through the claim coordinator's \`claim\` and
  \`release\` hooks, called through the plugin registry; the label calls (\`gh issue edit\`) are in
  \`plugins/claim-coordinator/github-labels/\`, and nothing under \`core/\` calls \`gh\` for the label.
  A test that registers a stub claim coordinator sees its \`claim\` hook called before the first
  stage and its \`release\` hook called on exit.
- **R7.** Tests cover R5 and R6."
_set_gh_mock "Claim an issue across machines" "$_body" 0
CHECK_REPLY="MISSING: RQCLM-1 $_R6_1 $_R6_2"; CHECK_REPLY_2=""
_intake
assert_eq "[M10] #1764's R6, hard-wrapped in its item, passes" "pass" "$OUTCOME"
assert_eq "[M10] ...on the first answer" "2" "$CALLS"
assert_eq "[M10] ...with no note" "" "$(_notes)"

_in "[M11] words between ids that are a part of a sentence are not the issue's" out \
    "RQCLM-1 and RQCLM-2 the check with that finding" "$_rev"
_in "[M11] ...nor words of two items run together around an id" out \
    "Tests cover RQLBL-1 and RQCLM-1 the same label" "$_body"
_in "[M11] ...nor the words in another order" out "RQLBL-1 and RQCLM-1 cover Tests." "$_body"
_in "[M11] the item with the list's ids for the issue's labels is" in "Tests cover RQLBL-1 and RQCLM-1." "$_body"
_in "[M11] ...as is one id for the two labels" in "Tests cover RQLBL-1." "$_body"

# M12: count how often the issue is made ready, through intake's own function.
eval "_m12_orig_$(declare -f _ireq_issue_norm_v)"
_M12_N=0
_ireq_issue_norm_v() { _M12_N=$(( _M12_N + 1 )); _m12_orig__ireq_issue_norm_v "$@"; }
CHECK_REPLY="MISSING: RQCLM-1 $_R6_1
MISSING: RQCLM-2 $_R6_2
MISSING: RQTST-1 Tests cover RQLBL-1 and RQCLM-1."
_intake
assert_eq "[M12] three MISSING lines: intake passes" "pass" "$OUTCOME"
assert_eq "[M12] ...and the issue is made ready once, for the one check call" "1" "$_M12_N"
eval "$(declare -f _m12_orig__ireq_issue_norm_v | sed '1s/_m12_orig__ireq_issue_norm_v/_ireq_issue_norm_v/')"

_in "[M13] a whole sentence" in "A part a check refused in an earlier try is shown to the check with that finding and the stage's answer." "$_rev"
_in "[M13] two whole sentences" in "A part a check refused in an earlier try is shown to the check with that finding and the stage's answer. #1764's case is judged." "$_rev"
_in "[M13] the stop left off" in "A part a check refused in an earlier try is shown to the check with that finding and the stage's answer" "$_rev"
_in "[M13] a curly apostrophe" in "A part a check refused in an earlier try is shown to the check with that finding and the stage’s answer." "$_rev"
_in "[M13] backticks dropped" in "The command zbuild run --issue N must print the run id (e.g. 42)." "$_rev"
_in "[M13] the item's own label kept" in "R3. The command \`zbuild run --issue N\` must print the run id (e.g. 42)." "$_rev"
_in "[M13] a numbered item" in "1. Intake keeps it whole." "$_rev"
_in "[M13] a part of a sentence" out "the check with that finding" "$_rev"
_in "[M13] an id the issue does not write" out "ZBR-3 the engine" "$_rev"
_in "[M13] one of the list's ids and words not the issue's" out "RQCLM-3 the engine" "$_rev"
_in "[M13] a paraphrase around an id" out "The command must print the run id, as RQCLM-3 says" "$_rev"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
