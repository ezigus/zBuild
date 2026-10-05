#!/usr/bin/env bash
# tests/integration/unowned-finding-test.sh — a finding nobody in a loop owns
# leaves that loop; a finding nobody at all owns stops the run (#2271).
#
# Why: the engine stops deciding who owns a finding; it only counts the answers
# stages give (Eric, 2026-10-04). If every build-side stage answers `nothing to
# do` to the same finding, the build loop ends early and the outer loop starts
# again at design, carrying every finding — no rule names design. If design also
# answers `nothing to do`, nobody owns it: the run stops with a report rather
# than circling. One `done` from anyone keeps a finding where it is.
#
# U1 [change] every build-side stage disclaims a finding → the build loop ends
#             early (does not use its remaining rounds) and the outer loop
#             starts again at design
# U2 [guard]  one build-side stage answers `done` → no early exit; the build
#             loop keeps its rounds
# U3 [change] design and impact (every answering stage before the build loop)
#             also disclaim it → the run stops; the report names the finding,
#             the stage that opened it, and every answer with its why
# U4 [change] design answers `done` → the run carries on: the build loop runs
#             again, starting at round 1
# U8 [guard]  with no stage before the yielding loop, nothing can disclaim: no
#             stop, and the yielded finding stays recorded
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a finding nobody owns leaves the loop, then stops the run (#2271)"
setup_test_env "unowned-finding"

# shellcheck source=../lib/unowned-finding-fixture.sh
source "$REPO_ROOT/tests/lib/unowned-finding-fixture.sh"

print_test_section "U1: every build-side stage disclaims the finding"
TA="nothing to do" BUILD="nothing to do" DESIGN="done" _run
assert_eq "[U1] the build loop ends early: it never reaches round 3" "0" "$(_count acc 3)"
assert_eq "[U1] the outer loop starts again at design" "2" "$(_count design 1)"

print_test_section "U2: one build-side stage did work on it"
TA="done" BUILD="nothing to do" DESIGN="done" _run
assert_eq "[U2] no early exit: the build loop keeps its rounds" "2" "$(_count acc 3)"

print_test_section "U3: design disclaims it too"
TA="nothing to do" BUILD="nothing to do" DESIGN="nothing to do" IMPACT="nothing to do" _run; rc=$?
if [[ "$rc" -ne 0 ]]; then
    assert_pass "[U3] the run stops (rc=$rc)"
else
    assert_fail "[U3] the run stops" "rc=0"
fi
assert_eq "[U3] the build loop does not run again after design disclaims it" "1" "$(_count test_author 1)"
_rep="$(cat "$ZBUILD_STATE_DIR/artifacts/unowned-findings.md" 2>/dev/null)"
assert_contains "[U3] the report names the finding" "$_rep" "acc finding 1"
assert_contains "[U3] ...and the stage that opened it" "$_rep" "opened by acc"
assert_contains "[U3] ...and its text" "$_rep" "is not the file that calls the new code"
assert_contains "[U3] ...and design's answer and why" "$_rep" "design: nothing to do — the wiring choice is right as written"
assert_contains "[U3] ...and build's answer" "$_rep" "build: nothing to do"
assert_contains "[U3] ...and impact's answer" "$_rep" "impact: nothing to do"

print_test_section "U4: design does the work"
TA="nothing to do" BUILD="nothing to do" DESIGN="done" _run
assert_eq "[U4] the build loop runs again, from round 1" "2" "$(_count test_author 1)"

print_test_section "U8: nothing ran before the yielding loop"
mkdir -p "$FA"; printf '{"loop":"build_loop","refs":["acc finding 1"],"answers":[]}\n' > "$ZBUILD_STATE_DIR/unowned-yield.json"
_unowned_halt_check "$ZBUILD_STATE_DIR"; _rc8=$?
assert_eq "[U8] no stop when no stage could have answered" "1" "$_rc8"
assert_eq "[U8] the yielded finding stays recorded" "present" \
    "$( [[ -s "$ZBUILD_STATE_DIR/unowned-yield.json" ]] && echo present || echo absent )"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
