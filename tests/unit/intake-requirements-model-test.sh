#!/usr/bin/env bash
# tests/unit/intake-requirements-model-test.sh — intake writes the issue's
# requirement list with a model call, and a second model call checks it caught
# everything (#2445, ADR-070 §1).
#
# Why: intake took only the issue's checkbox lines. An issue that wrote its
# requirements as a numbered list or as prose became one requirement — #2443's
# own five changes reached every later check as a single R-1. A model reads the
# issue as a person would; a second call checks the list against the issue. Both
# are given only the issue, and one turn each, so neither reads the code.
#
# I1 [change] a numbered list in the issue becomes one requirement per item,
#             numbered R-1, R-2, … by the engine, source "model"
# I2 [change] the check's missing items are added to the list
# I3 [change] the first call is given the issue and asked for every requirement
#             it states; it is told it is given only the issue and may not read
#             any file
# I4 [change] the second call is given the issue and the list, and asked what
#             the list misses
# I5 [change] each call has one turn (intake's manifest: max_turns 1), so it
#             cannot open the code
# I6 [change] a call that fails ends intake with that call's outcome, so the
#             engine can run it again; no list is written
# I7 [change] checkbox scraping is gone: an issue of checkboxes gets exactly the
#             model's list
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "intake writes the requirements with a model, and checks them (#2445)"
setup_test_env "intake-requirements-model"
# shellcheck source=../../plugins/agent/intake/tests/intake-test-lib.sh
source "$REPO_ROOT/plugins/agent/intake/tests/intake-test-lib.sh"
set +e
_REQ="$ARTIFACT_DIR/requirements.json"

# The model: call 1 lists requirements ($WRITE_REPLY), call 2 checks them
# ($CHECK_REPLY); FAIL_CALL=n makes call n fail with rc 124.
WRITE_REPLY=""; CHECK_REPLY="MISSING: none"; FAIL_CALL=0
route_to_model() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/calls"
    printf '%s' "$2" > "$TEST_TEMP_DIR/prompt-$n"
    [[ "$FAIL_CALL" == "$n" ]] && return 124
    if [[ "$n" == 1 ]]; then printf '%s\n' "$WRITE_REPLY"; else printf '%s\n' "$CHECK_REPLY"; fi
    return 0
}
_intake() {
    rm -f "$_REQ" "$TEST_TEMP_DIR"/calls "$TEST_TEMP_DIR"/prompt-*
    unset ZBUILD_GOAL 2>/dev/null || true
    export ZBUILD_ISSUE="$_ZB_ID"
    intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$ARTIFACT_DIR/intake-result.json" 2>/dev/null || echo MISSING)"
}

_body='The gate prints every line twice.

1. Print each line once.
2. Keep the exit code.
3. Say how many lines it printed.'
_set_gh_mock "Make the gate quieter" "$_body" 0

# ── I1 / I3 / I4 ─────────────────────────────────────────────────────────────
WRITE_REPLY='REQUIREMENT: Print each line once.
REQUIREMENT: Keep the exit code.'
CHECK_REPLY='MISSING: Say how many lines it printed.'
_intake
assert_eq "[I1] intake passes" "pass" "$OUTCOME"
assert_eq "[I1] the source is the model" "model" "$(jq -r '.source' "$_REQ" 2>/dev/null || echo MISSING)"
assert_eq "[I1][I2] one requirement per item, numbered by the engine, the check's missing one added" "R-1 R-2 R-3" \
    "$(jq -r '[.requirements[].id] | join(" ")' "$_REQ" 2>/dev/null || echo MISSING)"
assert_eq "[I1] R-1 is the first item's words" "Print each line once." "$(jq -r '.requirements[0].text' "$_REQ" 2>/dev/null)"
assert_eq "[I2] the check's missing item is added last" "Say how many lines it printed." "$(jq -r '.requirements[2].text' "$_REQ" 2>/dev/null)"
_p1="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/prompt-1" 2>/dev/null)"
assert_contains "[I3] the first call is given the issue" "$_p1" "Keep the exit code."
assert_contains "[I3] ...and asked for every requirement it states" "$_p1" "every requirement this issue states"
assert_contains "[I3] ...told it is given only the issue and may read no file" "$_p1" "Do not read any file"
_p2="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/prompt-2" 2>/dev/null)"
assert_contains "[I4] the check is given the issue" "$_p2" "Say how many lines it printed."
assert_contains "[I4] ...and the list" "$_p2" "Print each line once."
assert_contains "[I4] ...and asked what the list misses" "$_p2" "MISSING:"

# ── I5 ───────────────────────────────────────────────────────────────────────
assert_eq "[I5] each call has one turn" "1" \
    "$(awk '/^  router:/ { r = 1; next } r && /^    max_turns:/ { print $2; exit } r && /^  [^ ]/ { exit }' \
        "$REPO_ROOT/plugins/agent/intake/manifest.yaml")"

# ── I6 ───────────────────────────────────────────────────────────────────────
FAIL_CALL=1; _intake; FAIL_CALL=0
assert_eq "[I6] a call that times out ends intake timed_out" "timed_out" "$OUTCOME"
assert_file_not_exists "[I6] ...and no list is written" "$_REQ"

# ── I7 ───────────────────────────────────────────────────────────────────────
# Behaviour, not text: an issue made only of checkboxes gets exactly the list
# the model wrote — nothing scraped from the body joins it (review on #2446).
_set_gh_mock "Checkbox issue" $'- [ ] first box\n- [x] second box' 0
WRITE_REPLY='REQUIREMENT: what the model read'; CHECK_REPLY='MISSING: none'
_intake
assert_eq "[I7] the list is the model's alone; no checkbox is scraped into it" "what the model read" \
    "$(jq -r '[.requirements[].text] | join("|")' "$_REQ" 2>/dev/null || echo MISSING)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
