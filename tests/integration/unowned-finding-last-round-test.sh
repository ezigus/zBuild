#!/usr/bin/env bash
# tests/integration/unowned-finding-last-round-test.sh — a run whose last outer
# round ends with an item no stage can act on still writes the report (#2330,
# ADR-068 §8).
#
# Why: #2035 run 37450960900 ended on its last outer round with one requirement
# the judge was not sure of, which the build loop could not act on. The check
# that writes the report runs only when another round is coming, so no report
# was written and the run ended on "out of rounds" with nothing named.
#
# L1 [code] the build loop hands a finding back on the last outer round → the
#           run stops, the report names the item, what is unresolved, what would
#           settle it and every answer, and the loop's state says why it stopped
# L2 [code] a check is not sure of an item on the last outer round (no stage
#           handed it back) → the same report, naming the item
# L3 [code] the run runs out of rounds with an ordinary failing check → no such
#           report, but the run's open items still list the failure in plain words
# L4 [code] guard: the report and the open items contain no internal term, raw
#           code or number, and no "a person" / "human" wording
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../lib/plain-report-terms.sh
source "$REPO_ROOT/tests/lib/plain-report-terms.sh"
print_test_header "the last outer round still reports what no stage could act on (#2330)"
setup_test_env "unowned-finding-last-round"

# shellcheck source=../lib/unowned-finding-fixture.sh
source "$REPO_ROOT/tests/lib/unowned-finding-fixture.sh"
# shellcheck source=../../scripts/lib/run-open-items.sh
source "$REPO_ROOT/scripts/lib/run-open-items.sh" 2>/dev/null || true

REP="$ZBUILD_STATE_DIR/artifacts/unowned-findings.md"
_GUARDED=""

print_test_section "L1: the build loop hands the finding back on the last round"
TA="nothing to do" BUILD="nothing to do" DESIGN="done" _run; rc=$?
_rep="$(cat "$REP" 2>/dev/null)"; _GUARDED+=$'\n'"$_rep"
assert_eq "[L1] it was the last round: the build loop ran in both outer rounds" "2" "$(_count test_author 1)"
# #1850 (ADR-054 §4): was rc=8; the loop returns 1 and names a failed end.
assert_eq "[L1] the run stops as failed" "1 failed" "$rc ${_CYCLE_LAST_OUTCOME:-unset}"
assert_contains "[L1] the report names the item" "$_rep" "acc finding 1"
assert_contains "[L1] ...what is unresolved" "$_rep" "is not the file that calls the new code"
assert_contains "[L1] ...what would settle it" "$_rep" "What would settle it:"
assert_contains "[L1] ...and the answers" "$_rep" "build: nothing to do — the code passes the tests it was given"
assert_eq "[L1] the outer loop's state says why it stopped" "unowned_finding" \
    "$(jq -r '.cycle_iterations.outer_loop.status // empty' "$ZBUILD_STATE_DIR/pipeline-state.json" 2>/dev/null)"

print_test_section "L2: a check is not sure of an item on the last round"
ACC_UNSURE=1 TA="done" BUILD="done" DESIGN="done" _run; rc=$?
_rep="$(cat "$REP" 2>/dev/null)"; _GUARDED+=$'\n'"$_rep"
assert_eq "[L2] the build loop used every round: nothing handed it back" "2" "$(_count acc 3)"
assert_eq "[L2] the run stops as failed" "1 failed" "$rc ${_CYCLE_LAST_OUTCOME:-unset}"
assert_contains "[L2] the report names the item" "$_rep" "R-1: the flag is documented"
assert_contains "[L2] ...and what would settle it" "$_rep" "What would settle it: a test that fails when the flag is not documented"

print_test_section "L3: out of rounds with an ordinary failing check"
TA="done" BUILD="done" DESIGN="done" _run
assert_eq "[L3] no report of items no stage could act on" "absent" \
    "$( [[ -s "$REP" ]] && echo present || echo absent )"
_md="$(open_items_markdown "$ZBUILD_STATE_DIR" 2>/dev/null)"; _GUARDED+=$'\n'"$_md"
assert_contains "[L3] the open items still list the failure" "$_md" "is not the file that calls the new code"
assert_contains "[L3] ...with what would settle it" "$_md" "What would settle it:"

print_test_section "L4: guard — plain words only"
_bad="$(plain_report_violations "$_GUARDED")"
if [[ -z "$_bad" ]]; then
    assert_pass "[L4] the reports are in plain words"
else
    assert_fail "[L4] the reports are in plain words" "$_bad"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
