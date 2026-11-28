#!/usr/bin/env bash
# Integration: a run whose issue another run has claimed does not start
# (ADR-005 §1, issue #1764 R2), and this machine's admission lock is asked
# before the claim (ADR-059 §4).
#
# F1 zbuild:claimed on the issue: non-zero exit, no stage, pipeline.refused.claimed
#    with the holder, the holder printed as written (no escape is interpreted),
#    how to clear a claim whose run is gone, and end words that say the run did
#    not start (#2534)
# F2 a second run of an issue a run on this machine is working on is refused by
#    the admission lock, and never calls the coordinator
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../lib/claim-runner-fixture.sh
source "$REPO_ROOT/tests/lib/claim-runner-fixture.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../scripts/lib/run-status-render.sh
source "$REPO_ROOT/scripts/lib/run-status-render.sh"
# shellcheck source=../../scripts/lib/run-open-items.sh
source "$REPO_ROOT/scripts/lib/run-open-items.sh"

print_test_header "a claimed issue refuses the run; the admission lock is asked first"
setup_test_env "claim-refusal"
claim_fixture_setup

print_test_section "F1 refused"
claim_fixture_real_coordinator
ISSUE=90001811
HOLDER='run_id=holder-9\nx machine=other-box'      # a literal backslash-n
mkdir -p "$ZBUILD_CLAIM_STORE/$ISSUE"
printf 'zbuild:claimed\n' > "$ZBUILD_CLAIM_STORE/$ISSUE/labels.txt"
# The holder's run-status comment, made by the writer: its events, then its header.
ev="$TEST_TEMP_DIR/holder-events.jsonl"; : > "$ev"
ZBUILD_EVENTS_JSONL="$ev" ZBUILD_RUN_ID=holder-9 eb_emit_event pipeline.start "run_id=holder-9" "issue=$ISSUE" 2>/dev/null
ZBUILD_EVENTS_JSONL="$ev" ZBUILD_RUN_ID=holder-9 eb_emit_event pipeline.claim.acquired "holder=$HOLDER" 2>/dev/null
rsc_render_header "$(rsc_rows_json "$ev")" "$TEST_TEMP_DIR" > "$ZBUILD_CLAIM_STORE/$ISSUE/run-status-comment.txt" || true
STARTED="$TEST_TEMP_DIR/f1-started"; claim_fixture_stage ": > \"$STARTED\""
claim_fixture_run f1 --issue "$ISSUE"
assert_eq "[F1] the run exits non-zero" "1" "$(( CLAIM_RC != 0 ))"
assert_file_not_exists "[F1] no stage ran" "$STARTED"
assert_eq "[F1] pipeline.refused.claimed names the holder" "$HOLDER" \
    "$(jq -r 'select(.type == "pipeline.refused.claimed") | .data.holder' "$(claim_fixture_events f1)" 2>/dev/null)"
if /usr/bin/grep -qF "already claimed by another run: $HOLDER" "$TEST_TEMP_DIR/f1.out"; then
    assert_pass "[F1] the holder is printed as written (its \\n not interpreted)"
else
    assert_fail "[F1] the holder is printed as written (its \\n not interpreted)" "$(cat "$TEST_TEMP_DIR/f1.out")"
fi
assert_contains "[F1] the message says how to clear a claim whose run is gone" \
    "$(cat "$TEST_TEMP_DIR/f1.out")" "--remove-label zbuild:claimed"
assert_eq "[F1] the other run's claim is left in place" "zbuild:claimed" "$(cat "$ZBUILD_CLAIM_STORE/$ISSUE/labels.txt")"
# The words the run's completion comment opens with (CI's run_completion_body),
# from what the runner wrote (#2534: the run that loses says it did not start).
_f1_words="$(run_end_words "$(run_end_reason "$(dirname "$(claim_fixture_events f1)")")" 0)"
assert_eq "[#2534/SPEC-1] the run's end words say it did not start, and why" \
    "did not start: another run is working on this issue" "$_f1_words"
assert_contains "[#2534/SPEC-1] ...and its completion comment opens with them" \
    "$(run_completion_body failure "" "" "https://github.com/o/r/actions/runs/1" "" "" "$_f1_words")" \
    "**zbuild pipeline did not start: another run is working on this issue.**"

print_test_section "F2 the admission lock refuses before the claim"
unset ZBUILD_NO_ISSUE_LOCK
claim_fixture_stub_coordinator '{"acquired": true}'
STARTED="$TEST_TEMP_DIR/f2-started"; GO="$TEST_TEMP_DIR/f2-go"
claim_fixture_stage ": > \"$STARTED\"; for _ in \$(seq 1 600); do [[ -e \"$GO\" ]] && break; sleep 0.05; done"
claim_fixture_start f2-first --issue 90001812
FIRST_PID="$CLAIM_PID"
claim_fixture_wait_for "$STARTED" || assert_fail "[F2] setup: the first run's stage started" "$(tail -5 "$TEST_TEMP_DIR/f2-first.out")"
claim_fixture_run f2-second --issue 90001812
second_rc="$CLAIM_RC"
: > "$GO"
claim_fixture_wait_gone "$FIRST_PID"
assert_eq "[F2] the second run is refused" "1" "$(( second_rc != 0 ))"
assert_eq "[F2] …by the admission lock" "1" \
    "$(jq -c 'select(.type == "pipeline.refused.issue_locked")' "$(claim_fixture_events f2-second)" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[F2] the coordinator was asked once, by the first run only" "1" \
    "$(/usr/bin/grep -c '^claim ' "$CLAIM_CALLS" || true)"
export ZBUILD_NO_ISSUE_LOCK=1

print_test_results
exit $((FAIL > 0))
