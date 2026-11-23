#!/usr/bin/env bash
# tests/unit/run-stop-names-blocker-test.sh — the end of every run says why it
# stopped, naming the blocker, and its open items include every stage's failed
# checks (#2586 R7; ADR-064 §4, ADR-068 §8).
#
# Why: #2532 run 45017980554 ended `out_of_tries:build_test_cycle`. The status
# comment's header showed no stop line, the completion comment said only
# "build_test_cycle found no way forward in its tries", and the open items
# missed build's unfinished step and the failing test: they were read only from
# `*-result.json` files, and build's result is build-summary.json, the test
# stage's test-results.json.
#
# B1 [change] build's result (build-summary.json) that did not pass is an open
#             item: its finding, by its id
# B2 [change] the test stage's result (test-results.json) that failed is one too
# B3 [guard]  a stage whose findings travel in its own `<name>-*-result.json`
#             files is read through those: its own `<name>.json` adds nothing
# B4 [guard]  a passing result named otherwise is no open item
# B5 [change] the status header of a run that ended says why — the end words —
#             and names each blocker by its id, with no aborted event
# B6 [guard]  a running run's header names no blocker
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "the end of a run says why it stopped and names the blocker (#2586)"
setup_test_env "run-stop-names-blocker"

# shellcheck source=../../scripts/lib/run-status-comment.sh
source "$REPO_ROOT/scripts/lib/run-status-comment.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

S="$TEST_TEMP_DIR/s"; A="$S/artifacts"; mkdir -p "$A"
# Each result by the engine's writer, as the run left them.
stage_result_write "$A/build-summary.json" unusable "design_steps_not_done" \
    '{"findings":[{"n":1,"id":"BUFND-35","text":"step 2: your reason it is not needed does not hold: the guard misses the two-line form — ACCEPTED IF: the guard fails on either form"}]}' >/dev/null
stage_result_write "$A/test-results.json" fail "1 of 951 tests failed" \
    '{"findings":[{"n":1,"id":"TEFND-1","text":"tests/integration/claim-release-on-exit-test.sh fails: [C7] the claim is released"}]}' >/dev/null
# The test stage also routes its findings to test-code-result.json (review of
# #2586): the same finding is listed once.
stage_result_write "$A/test-code-result.json" fail "1 finding" \
    '{"findings":[{"n":1,"id":"TEFND-1","text":"tests/integration/claim-release-on-exit-test.sh fails: [C7] the claim is released"}]}' >/dev/null
stage_result_write "$A/lens-red-team.json" fail "2 findings" \
    '{"findings":[{"n":1,"text":"LENS PRIMARY TEXT"}]}' >/dev/null
stage_result_write "$A/lens-red-team-code-result.json" fail "2 findings" \
    '{"findings":[{"n":1,"id":"RLREDTEAM-4","text":"the two-line pattern passes the guard"}]}' >/dev/null
stage_result_write "$A/design-verdict.json" pass "the design holds" \
    '{"findings":[{"n":1,"text":"PASSING DESIGN TEXT"}]}' >/dev/null

_md="$(open_items_markdown "$S")"
print_test_section "B1-B4: every stage's failed checks"
assert_contains "[B1] build's unfinished step is an open item, by its id" "$_md" "**BUFND-35** (opened by build)"
assert_contains "[B2] the failing test is one, by its id" "$_md" "**TEFND-1** (opened by test)"
assert_contains "[B3] the lens's routed finding is listed" "$_md" "RLREDTEAM-4"
assert_eq "[B3] ...its own lens-<id>.json adds nothing" "0" "$(grep -c 'LENS PRIMARY TEXT' <<< "$_md" || true)"
assert_eq "[B4] a passing result named otherwise is no item" "0" "$(grep -c 'PASSING DESIGN TEXT' <<< "$_md" || true)"
assert_eq "[B1-B3] three open items" "3" "$(open_items_count "$S")"
assert_eq "[B7] a finding routed to two files is one item" "1" "$(grep -c 'TEFND-1' <<< "$_md" || true)"

print_test_section "B5-B6: the header says why, and names the blocker"
export ZBUILD_EVENTS_JSONL="$S/events.jsonl" ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
: > "$ZBUILD_EVENTS_JSONL"
eb_emit_event "pipeline.start" "run_id=r-2586" "issue=2586" >/dev/null 2>&1
_run="$(ZBUILD_STATUS_NOW=2026-11-22T12:00:00Z rsc_render_body "$ZBUILD_EVENTS_JSONL" "$S")"
_meta_run="$(grep -m1 '^engine ' <<< "$_run")"
if [[ "$_meta_run" == *"blocked by"* ]]; then assert_fail "[B6] a running run's header names no blocker" "$_meta_run"
else assert_pass "[B6] a running run's header names no blocker"; fi
eb_emit_event "pipeline.end" "status=failed" "cycle=delivery_loop" "reason=out_of_tries:build_test_cycle" >/dev/null 2>&1
_b="$(ZBUILD_STATUS_NOW=2026-11-22T13:00:00Z rsc_render_body "$ZBUILD_EVENTS_JSONL" "$S")"
_meta="$(grep -m1 '^engine ' <<< "$_b")"
assert_contains "[B5] the header line says why the run stopped" "$_meta" "stopped: build_test_cycle found no way forward in its tries"
assert_contains "[B5] ...and names each blocker by its id" "$_meta" "blocked by BUFND-35 (build), RLREDTEAM-4 (lens-red-team-code), TEFND-1 (test)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
