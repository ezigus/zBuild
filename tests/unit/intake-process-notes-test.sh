#!/usr/bin/env bash
# tests/unit/intake-process-notes-test.sh — a note about how or when to run the
# work is not a requirement (ADR-070 §1, amended 2026-11-06, #2476).
#
# Why: #1805's "Order: do not run this in parallel with #1714" became ORDE-1.
# No code or test can show it, so it stayed UNSURE through every round of run
# 42127743259: one of the run's ten open items.
#
# P1 [change] the writing call is told a note about order, scheduling or what
#             to run alongside is not a requirement
# P2 [change] the check call is told it may answer NOT-A-REQUIREMENT for one
# P3 [change] an item the check answers NOT-A-REQUIREMENT for leaves the list,
#             kept as removed with the check's reason, so it never comes back
# P4 [guard]  NOT-A-REQUIREMENT for an id the list does not have is asked again
# P5 [change] (#2527) the check call is shown each removed item with its words
#             and why, not only its id, and told such an item needs no line
# P6 [change] (#2527) ...and NOT-A-REQUIREMENT for an id the list does not have
#             is asked again with "leave the line out", never "name a listed id".
#             #1805 run 43130129438: shown only removed ids, the check named the
#             removed cycle note again as RQTEST-2; told to name a listed id, it
#             named RQRESU-4, a real requirement, and that left the list.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a note about how or when to run the work is not a requirement (#2476)"
setup_test_env "intake-process-notes"
# shellcheck source=../../plugins/agent/intake/tests/intake-test-lib.sh
source "$REPO_ROOT/plugins/agent/intake/tests/intake-test-lib.sh"
set +e
_REQ="$ARTIFACT_DIR/requirements.json"
assert_not_contains() {
    if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "found: $3"; else assert_pass "$1"; fi
}

declare -a REPLY=()
route_to_model() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/calls"
    printf '%s' "$2" > "$TEST_TEMP_DIR/prompt-$n"
    printf '%s\n' "${REPLY[$n]:-MISSING: none}"
    return 0
}
_intake() {
    rm -f "$TEST_TEMP_DIR"/calls "$TEST_TEMP_DIR"/prompt-* "$_REQ"
    unset ZBUILD_GOAL 2>/dev/null || true
    export ZBUILD_ISSUE="$_ZB_ID"
    intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$ARTIFACT_DIR/intake-result.json" 2>/dev/null || echo MISSING)"
}
_ids() { jq -r '[.requirements[]?.id] | join(" ")' "$_REQ" 2>/dev/null; }
_prompt() { tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/prompt-$1" 2>/dev/null; }

_set_gh_mock "Rehydrate on resume" $'1. Rehydrate every stage.\n\nOrder: do not run this in parallel with #1714.' 0

# ── P1 / P2 / P3 ─────────────────────────────────────────────────────────────
REPLY=([1]=$'REQUIREMENT: RQRHYD-1 Rehydrate every stage.\nREQUIREMENT: RQORDE-1 Do not run this in parallel with #1714.'
       [2]=$'MISSING: none\nNOT-A-REQUIREMENT: RQORDE-1 — it says when to run the work; no change can show it')
_intake
assert_contains "[P1] the writing call is told a note about when to run the work is not a requirement" \
    "$(_prompt 1)" "how or when to do the work"
assert_contains "[P2] the check call may answer NOT-A-REQUIREMENT" "$(_prompt 2)" "NOT-A-REQUIREMENT: <id> — <why>"
assert_eq "[P3] the note leaves the list" "RQRHYD-1" "$(_ids)"
assert_eq "[P3] ...kept as removed, with the check's reason" \
    "RQORDE-1|Do not run this in parallel with #1714.|it says when to run the work; no change can show it" \
    "$(jq -r '.removed[]? | select(.id == "RQORDE-1") | "\(.id)|\(.text)|\(.reason)"' "$_REQ" 2>/dev/null)"
assert_eq "[P3] intake passes" "pass" "$OUTCOME"

# ── P4 ───────────────────────────────────────────────────────────────────────
REPLY=([1]=$'REQUIREMENT: RQRHYD-1 Rehydrate every stage.'
       [2]=$'NOT-A-REQUIREMENT: RQNOPE-1 — never listed'
       [3]=$'MISSING: none')
_intake
assert_contains "[P4] NOT-A-REQUIREMENT for an id the list lacks is asked again" "$(_prompt 3)" "RQNOPE-1"
assert_eq "[P4] ...and answered right, intake passes with its list" "RQRHYD-1" "$(_ids)"
assert_contains "[P6] ...told to leave that line out" "$(_prompt 3)" "RQNOPE-1 is not in the list, so leave that line out"
assert_not_contains "[P6] ...never to name a listed id" "$(_prompt 3)" "name only a listed id"

# ── P5 ───────────────────────────────────────────────────────────────────────
# The last run removed the order note (P3's list); the issue has since changed,
# so both calls are made again.
REPLY=([1]=$'REQUIREMENT: RQRHYD-1 Rehydrate every stage.\nREQUIREMENT: RQORDE-1 Do not run this in parallel with #1714.'
       [2]=$'MISSING: none\nNOT-A-REQUIREMENT: RQORDE-1 — it says when to run the work; no change can show it')
_intake
_set_gh_mock "Rehydrate on resume" $'1. Rehydrate every stage, in order.\n\nOrder: do not run this in parallel with #1714.' 0
REPLY=([1]=$'REQUIREMENT: RQRHYD-1 Rehydrate every stage, in order.' [2]=$'MISSING: none')
rm -f "$TEST_TEMP_DIR"/calls "$TEST_TEMP_DIR"/prompt-*
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
assert_contains "[P5] the check is shown a removed item's words" "$(_prompt 2)" "RQORDE-1 — Do not run this in parallel with #1714."
assert_contains "[P5] ...and why it was removed" "$(_prompt 2)" "it says when to run the work; no change can show it"
assert_contains "[P5] ...and told it needs no line" "$(_prompt 2)" "An item already removed needs no line"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
