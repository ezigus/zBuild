#!/usr/bin/env bash
# tests/unit/intake-previous-list-test.sh — intake starts from its last list,
# keeps its latest, and says what changed (#2460, ADR-070 §2).
#
# Why: over the same issue text intake listed 17, 15, 15, 14 and 16
# requirements in successive runs of #1805 — its check call finds different
# misses each time — and said nothing. On run 41546214211 it added R-15 and
# R-16; design's carried-over work did not cover them and design's first try
# failed its checks, ten minutes spent finding out.
#
# P1 [change] the writing call is shown the list from the last run, and told to
#             start from it
# P2 [change] a list that differs from the last says what was added and what was
#             removed, in intake's result and in its summary
# P3 [change] a list the same as the last says so
# P4 [guard]  with no list from a last run there is nothing to start from and no
#             change to report
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "intake starts from its last list and says what changed (#2460)"
setup_test_env "intake-previous-list"
# shellcheck source=../../plugins/agent/intake/tests/intake-test-lib.sh
source "$REPO_ROOT/plugins/agent/intake/tests/intake-test-lib.sh"
set +e
_REQ="$ARTIFACT_DIR/requirements.json"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

WRITE_REPLY=""; CHECK_REPLY="MISSING: none"
route_to_model() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/calls"
    printf '%s' "$2" > "$TEST_TEMP_DIR/prompt-$n"
    if [[ "$n" == 1 ]]; then printf '%s\n' "$WRITE_REPLY"; else printf '%s\n' "$CHECK_REPLY"; fi
    return 0
}
_prev() {   # the list a last run left: one requirement per argument
    if [[ $# -eq 0 ]]; then rm -f "$_REQ"; return; fi
    printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))
        | {schema_version: 1, source: "model", requirements: [to_entries[] | {id: "R-\(.key + 1)", text: .value}]}' > "$_REQ"
}
_intake() {
    rm -f "$TEST_TEMP_DIR"/calls "$TEST_TEMP_DIR"/prompt-*
    unset ZBUILD_GOAL 2>/dev/null || true
    export ZBUILD_ISSUE="$_ZB_ID"
    intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
    RES="$ARTIFACT_DIR/intake-result.json"; SUM="$(cat "$ARTIFACT_DIR/intake-summary.md" 2>/dev/null)"
}

_set_gh_mock "Make the gate quieter" $'1. Print each line once.\n2. Keep the exit code.\n3. Say how many lines it printed.' 0

# ── P1 / P2 ──────────────────────────────────────────────────────────────────
_prev "Print each line once." "Keep the exit code." "Exit 2 on a bad flag."
WRITE_REPLY=$'REQUIREMENT: Print each line once.\nREQUIREMENT: Keep the exit code.'
CHECK_REPLY='MISSING: Say how many lines it printed.'
_intake
_p1="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/prompt-1" 2>/dev/null)"
assert_contains "[P1] the writing call is shown the last run's list" "$_p1" "Exit 2 on a bad flag."
assert_contains "[P1] ...and told to start from it" "$_p1" "start from it"
assert_eq "[P2] the result names what was added" "Say how many lines it printed." \
    "$(jq -r '.data.requirements_changed.added[]?' "$RES" 2>/dev/null)"
assert_eq "[P2] ...and what was removed" "Exit 2 on a bad flag." \
    "$(jq -r '.data.requirements_changed.removed[]?' "$RES" 2>/dev/null)"
assert_contains "[P2] the summary says the list changed" "$SUM" "changed since the last run"
assert_contains "[P2] ...naming the addition" "$SUM" "added: Say how many lines it printed."
assert_contains "[P2] ...and the removal" "$SUM" "removed: Exit 2 on a bad flag."

# ── P3 ───────────────────────────────────────────────────────────────────────
_prev "Print each line once." "Keep the exit code." "Say how many lines it printed."
WRITE_REPLY=$'REQUIREMENT: Print each line once.\nREQUIREMENT: Keep the exit code.\nREQUIREMENT: Say how many lines it printed.'
CHECK_REPLY='MISSING: none'
_intake
assert_contains "[P3] a list the same as the last says so" "$SUM" "the same as the last run's"
assert_eq "[P3] ...nothing added or removed" "0 0" \
    "$(jq -r '"\(.data.requirements_changed.added | length) \(.data.requirements_changed.removed | length)"' "$RES" 2>/dev/null)"

# ── P4 ───────────────────────────────────────────────────────────────────────
_prev
_intake
_lacks "[P4] with no last list, the call is not told of one" "$(cat "$TEST_TEMP_DIR/prompt-1" 2>/dev/null)" "last run"
_lacks "[P4] ...and the summary reports no change" "$SUM" "last run"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
