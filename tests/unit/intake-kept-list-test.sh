#!/usr/bin/env bash
# tests/unit/intake-kept-list-test.sh — intake keeps its list, with no model
# call, while the issue and intake's instructions are unchanged (#2477,
# ADR-070 §1 §2).
#
# Why: intake asked its model to read the issue on every run. On #1805 run
# 42127743259 it added a requirement to an issue nobody had changed, and design
# lost a try renaming a SPEC for it. Finished work should stay finished: the
# same issue under the same engine gives the same list, so it is not asked for.
#
# K1 [change] a second run on an unchanged issue makes no model call, keeps the
#             list as it was, says so, and leaves intake.requirements.kept
# K2 [guard]  a change to the issue's words makes the calls
# K3 [guard]  a change to intake's instructions makes the calls
# K4 [guard]  another engine makes the calls
# K5 [guard]  a list with no record of what it was written from makes the calls
# K6 [guard]  a comment on the issue (not read for the list) does not
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "intake keeps its list while nothing it reads changed (#2477)"
setup_test_env "intake-kept-list"
# shellcheck source=../../plugins/agent/intake/tests/intake-test-lib.sh
source "$REPO_ROOT/plugins/agent/intake/tests/intake-test-lib.sh"
set +e
_REQ="$ARTIFACT_DIR/requirements.json"

route_to_model() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/calls"
    if [[ "$2" == *"check a list of requirements"* ]]; then printf 'MISSING: none\n'
    else printf 'REQUIREMENT: RQLINE-1 Print each line once.\nREQUIREMENT: RQCODE-1 Keep the exit code.\n'; fi
    return 0
}
_calls() { cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0; }
_kept_events() { /usr/bin/grep -c '"intake.requirements.kept"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true; }
# The list is made by intake itself (#1799: data is made by its writer).
_intake() {
    rm -f "$TEST_TEMP_DIR/calls"
    unset ZBUILD_GOAL 2>/dev/null || true
    export ZBUILD_ISSUE="$_ZB_ID"
    intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
    RES="$ARTIFACT_DIR/intake-result.json"; SUM="$(cat "$ARTIFACT_DIR/intake-summary.md" 2>/dev/null)"
}
_fresh() { rm -f "$_REQ"; _RUNNER_ENGINE_SHA="engine-a"; _intake; }

_BODY=$'1. Print each line once.\n2. Keep the exit code.'
_set_gh_mock "Make the gate quieter" "$_BODY" 0

# ── K1 ───────────────────────────────────────────────────────────────────────
_fresh
assert_eq "[K1] setup: the first run writes the list with its two calls" "2" "$(_calls)"
_first="$(cat "$_REQ" 2>/dev/null)"
_ev0="$(_kept_events)"
_intake
assert_eq "[K1] a second run on the unchanged issue makes no model call" "0" "$(_calls)"
assert_eq "[K1] ...and keeps the list exactly as it was" "$_first" "$(cat "$_REQ" 2>/dev/null)"
assert_eq "[K1] ...intake passes" "pass" "$(jq -r '.outcome' "$RES" 2>/dev/null)"
assert_contains "[K1] ...its summary says the list was kept because the issue is unchanged" "$SUM" "kept"
assert_eq "[K1] ...and nothing was added or removed" "0 0" \
    "$(jq -r '"\(.data.requirements_changed.added | length) \(.data.requirements_changed.removed | length)"' "$RES" 2>/dev/null)"
assert_eq "[K1] ...and intake.requirements.kept is emitted" "$(( _ev0 + 1 ))" "$(_kept_events)"

# ── K2 ───────────────────────────────────────────────────────────────────────
_fresh
_set_gh_mock "Make the gate quieter" "$_BODY"$'\n3. Exit 2 on a bad flag.' 0
_intake
assert_eq "[K2] a change to the issue's words makes both calls" "2" "$(_calls)"
_set_gh_mock "Make the gate quieter" "$_BODY" 0

# ── K3 ───────────────────────────────────────────────────────────────────────
_fresh
eval "$(declare -f _ireq_check_own | sed 's/Name every requirement/List every requirement/')"
_intake
assert_eq "[K3] a change to intake's instructions makes both calls" "2" "$(_calls)"
eval "$(declare -f _ireq_check_own | sed 's/List every requirement/Name every requirement/')"

# ── K4 ───────────────────────────────────────────────────────────────────────
_fresh
_RUNNER_ENGINE_SHA="engine-b"
_intake
assert_eq "[K4] another engine makes both calls" "2" "$(_calls)"

# ── K5 ───────────────────────────────────────────────────────────────────────
_fresh
jq -c 'del(.input_fp)' "$_REQ" > "$_REQ.tmp" && mv "$_REQ.tmp" "$_REQ"
_intake
assert_eq "[K5] a list with no record of what it was written from makes both calls" "2" "$(_calls)"

# ── K6 ───────────────────────────────────────────────────────────────────────
_fresh
export MOCK_GH_COMMENTS='[{"authorAssociation":"OWNER","author":{"login":"someone"},"body":"Looks good."}]'
_intake
assert_eq "[K6] a new comment (the list never reads comments) makes no call" "0" "$(_calls)"
unset MOCK_GH_COMMENTS

cleanup_test_env
print_test_results
exit $((FAIL > 0))
