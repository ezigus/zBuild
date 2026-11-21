#!/usr/bin/env bash
# tests/unit/finding-ids-writers-test.sh — every writer keeps the id record, a
# finding sent to several topics has one id, and an answer is read only by the
# finding it names (review of #2574; ADR-068 §5 §6, ADR-072 §4).
#
# W1 [change] build's summary keeps its id record: two tries with different
#             findings give different ids, and build-tests and the summary of
#             one try number from the same record
# W2 [change] a finding sent to several topics has the same id in every output
#             and in the stage's own list, and keeps it on the next try —
#             issue-acceptance's three-topic finding, and the test tool's
# W3 [change] a kept line that starts with a verdict word is read by that word
#             alone: `UNMET: None of …` is a refusal
# W4 [change] an answer in the old form, `<label> finding <n>`, is read only
#             against a finding that has no id
# W5 [change] the id record is written whole (atomic_write); a record that
#             cannot be written leaves an event
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "finding ids: every writer, every topic, every reader (#2574 review)"
setup_test_env "finding-ids-writers"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"
# shellcheck source=../../scripts/lib/stage-handoff.sh
source "$REPO_ROOT/scripts/lib/stage-handoff.sh"
# shellcheck source=../../scripts/lib/judge.sh
source "$REPO_ROOT/scripts/lib/judge.sh"
_ids() { jq -r '[.data.findings[]? | .id] | join(" ")' "$1" 2>/dev/null; }

print_test_section "W1: build's summary keeps its id record"
(
    # shellcheck source=../../plugins/agent/build/lib/summary.sh
    source "$REPO_ROOT/plugins/agent/build/lib/summary.sh"
    D="$TEST_TEMP_DIR/w1"; mkdir -p "$D"
    output_summary_json="$D/build-summary.json"; build_verdict=fail; build_reason=x; scope_violation=true
    scope_violations=(tests/a-test.sh); _build_write_build_summary >/dev/null 2>&1
    echo "try1=$(_ids "$D/build-summary.json")"
    scope_violations=(tests/b-test.sh); _build_write_build_summary >/dev/null 2>&1
    echo "try2=$(_ids "$D/build-summary.json")"
    D="$TEST_TEMP_DIR/w1b"; mkdir -p "$D"; output_summary_json="$D/build-summary.json"
    _ROUTE_LOOP_LAST_RESPONSE='ANSWER TAFND-4: not mine — the test must change: tests/x-test.sh: it pins the old label'
    _build_write_test_findings "$D" >/dev/null 2>&1
    scope_violations=(tests/a-test.sh); _build_write_build_summary >/dev/null 2>&1
    echo "tests=$(_ids "$D/build-tests-result.json") summary=$(_ids "$D/build-summary.json") highest=$(jq -r .highest "$D/finding-ids-BUFND.json" 2>/dev/null)"
) > "$TEST_TEMP_DIR/w1.log" 2>&1
assert_contains "[W1] try 1's finding is BUFND-1" "$(cat "$TEST_TEMP_DIR/w1.log")" "try1=BUFND-1"
assert_contains "[W1] try 2's other finding takes BUFND-2, never BUFND-1 again" "$(cat "$TEST_TEMP_DIR/w1.log")" "try2=BUFND-2"
assert_contains "[W1] build-tests and the summary share the record" "$(cat "$TEST_TEMP_DIR/w1.log")" "tests=BUFND-1 summary=BUFND-2 highest=2"

print_test_section "W2: a finding sent to several topics has one id"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
( source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" >/dev/null 2>&1
  D="$TEST_TEMP_DIR/w2"; mkdir -p "$D"
  _IA_ANSWERS=(); _ia_write "$D" fail "one unmet" '["RQX-1: the flag is not read — p.sh | flag=1 — ACCEPTED IF: the flag is read"]' >/dev/null 2>&1
  echo "own1=$(_ids "$D/issue-acceptance-result.json") d=$(_ids "$D/issue-acceptance-design-result.json") t=$(_ids "$D/issue-acceptance-test-result.json") c=$(_ids "$D/issue-acceptance-code-result.json")"
  _ia_write "$D" fail "one unmet" '["RQX-1: the flag is not read — p.sh | flag=1 — ACCEPTED IF: the flag is read"]' >/dev/null 2>&1
  echo "own2=$(_ids "$D/issue-acceptance-result.json") d=$(_ids "$D/issue-acceptance-design-result.json") t=$(_ids "$D/issue-acceptance-test-result.json") c=$(_ids "$D/issue-acceptance-code-result.json")"
) > "$TEST_TEMP_DIR/w2.log" 2>&1
assert_contains "[W2] issue-acceptance: one id in its list and all three outputs" "$(cat "$TEST_TEMP_DIR/w2.log")" "own1=IAFND-1 d=IAFND-1 t=IAFND-1 c=IAFND-1"
assert_contains "[W2] ...and the same on the next try" "$(cat "$TEST_TEMP_DIR/w2.log")" "own2=IAFND-1 d=IAFND-1 t=IAFND-1 c=IAFND-1"
D="$TEST_TEMP_DIR/w2t"; mkdir -p "$D"
for _n in 1 2; do
    _own="$(printf 'design-findings,test-findings,code-findings\tthe acceptance check failed\n' | stage_findings_route_each "$D" test code-findings TEFND)"
    assert_eq "[W2] the test tool, try $_n: one id in its list and every output" "TEFND-1|TEFND-1|TEFND-1|TEFND-1" \
        "$(jq -r '.[0].id' <<< "$_own")|$(_ids "$D/test-design-result.json")|$(_ids "$D/test-test-result.json")|$(_ids "$D/test-code-result.json")"
done

print_test_section "W3: a verdict word at the start of a line is the verdict"
for _l in "UNMET: None of the flags are parsed | WHY: x" "UNMET: Kept nothing" "BROKEN: none of LIM-1 holds"; do
    if judge_refused "$_l" met kept none; then assert_pass "[W3] refused: $_l"; else assert_fail "[W3] refused: $_l" "read as a pass"; fi
done
if judge_refused "MET: RQX-1 | x" met kept none; then assert_fail "[W3] MET passes" "refused"; else assert_pass "[W3] MET passes"; fi
if judge_refused "RQCL-1: covered" ok covered; then assert_fail "[W3] <id>: covered passes" "refused"; else assert_pass "[W3] <id>: covered passes"; fi

print_test_section "W4: an old-form answer names only a finding with no id"
D4="$TEST_TEMP_DIR/w4"; mkdir -p "$D4"
stage_result_write "$D4/x-result.json" fail "two" '{"findings":[{"n":1,"id":"XXFND-7","text":"has an id"},{"n":2,"text":"no id"}]}' >/dev/null
declare -A _af=()
_JUDGE_ANSWER_FINDING=()
judge_answered_findings_v _af $'x finding 1: done — a\nx finding 2: done — b' "x=$D4/x-result.json"
assert_eq "[W4] 'x finding 1' does not name the finding that has an id" "" "${_af[x finding 1]%%$'\x1f'*}"
assert_eq "[W4] 'x finding 2' names the one with none" "no id" "${_af[x finding 2]%%$'\x1f'*}"

print_test_section "W5: the id record is written whole"
D5="$TEST_TEMP_DIR/w5"; mkdir -p "$D5"
printf 'a\n' | stage_findings_json "$D5" BUFND >/dev/null
assert_eq "[W5] written" "1" "$(jq -r .highest "$D5/finding-ids-BUFND.json" 2>/dev/null)"
chmod a-w "$D5"
printf 'b\n' | stage_findings_json "$D5" BUFND >/dev/null 2>&1
chmod u+w "$D5"
assert_contains "[W5] a record that could not be written leaves an event" "$(cat "$ZBUILD_EVENTS_JSONL")" "finding_ids.write_failed"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
