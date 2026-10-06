#!/usr/bin/env bash
# tests/unit/finding-answers-test.sh — every stage answers every finding it
# receives, and only the stage that opened a finding can close it (#2271).
#
# Why: the engine stops deciding who owns a finding. Each stage sees every
# finding and answers each one with a standard word (Eric, 2026-10-04):
#   done — what it changed      nothing to do — why      (any stage)
#   satisfied — why             (only the stage that opened the finding)
# More than one stage may work on the same finding; another stage's `done` does
# not mean this stage has nothing to do. The engine records who answered.
#
# A1 [guard]  no findings in the prompt → no answers block
# A2 [change] findings in the prompt → the block asks for an answer to each,
#             gives the three words, says that more than one stage may do work
#             on a finding, and that a `done` says what was changed
# A3 [change] a stage that opened findings last round is shown them and asked
#             whether each is `satisfied`
# A4 [change] answers are read from the reply, keyed by the finding reference,
#             with the answering stage recorded; malformed lines are ignored
# A5 [change] `satisfied` counts only from the stage that opened the finding
# A6 [change] the router appends the block to a prompt with findings, once
# A7 [change] through the whole funnel: findings that arrive with the stage
#             summaries are asked about — the block comes after them, and
#             before redaction (#2294: it was appended before the summaries,
#             so no live stage was ever asked)
# A8 [change] an answer line wrapped in common markdown is still read: bold
#             with the colon inside or outside, inline code, a leading `- `,
#             `* ` or `> `; the answer word in any case. The line must still
#             have the `ANSWER <stage> finding <n>:` shape (#2322: design
#             answered in bold three times and none was recorded)
# A9 [change] one vocabulary: `NOT_REPRODUCED` / `not reproduced` is recorded
#             as `nothing to do`, and the reason is kept (#2322: build's
#             NOT_REPRODUCED answer was not recorded)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every stage answers every finding it receives (#2271)"
setup_test_env "finding-answers"
export ZBUILD_EVENTS_DB="/dev/null"
# shellcheck source=../../scripts/lib/stage-answers.sh
source "$REPO_ROOT/scripts/lib/stage-answers.sh" 2>/dev/null || true

P="$TEST_TEMP_DIR/prompt.txt"
printf 'Do your task.\n' > "$P"
assert_eq "[A1] no findings → no block" "" "$(ZBUILD_CURRENT_STAGE=build answers_prompt_block "$P" 2>/dev/null)"

cat > "$P" <<'EOF'
Do your task.

### acceptance-gate (verdict: fail)
- acceptance-gate finding 1 (opened by acceptance-gate): config/event-schema.json is not the file that calls the new code
- acceptance-gate finding 2 (opened by acceptance-gate): SPEC-3's test already passes on the old code
EOF
_b="$(ZBUILD_CURRENT_STAGE=test-author answers_prompt_block "$P" 2>/dev/null)"
assert_contains "[A2] the block asks for every finding" "$_b" "Answer every finding"
assert_contains "[A2] it gives the done word" "$_b" "done —"
assert_contains "[A2] it gives the nothing-to-do word" "$_b" "nothing to do —"
assert_contains "[A2] a done says what was changed" "$_b" "what you changed"
assert_contains "[A2] more than one stage may work on a finding" "$_b" "more than one stage"
assert_contains "[A2] another stage's done is not this stage's answer" "$_b" "does not mean you have nothing to do"
assert_contains "[A2] the answer format" "$_b" "ANSWER acceptance-gate finding 1:"

S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts" "$TEST_TEMP_DIR/plugins/agent/judge"
cat > "$TEST_TEMP_DIR/plugins/agent/judge/manifest.yaml" <<'MF'
id: judge
kind: agent
provides:
  role: judge
  result_contract: 2
outputs:
  - id: judge-result
    path: ${artifact_dir}/judge-result.json
    format: json
    required: true
    primary: true
MF
jq -n '{result_contract:2, verdict:"fail", disposition:"complete", reason:"x",
        data:{findings:[{n:1,text:"the issue asks for a dry run and no SPEC covers it"}]}}' > "$S/artifacts/judge-result.json"
_b3="$(ZBUILD_CURRENT_STAGE=judge ZBUILD_STATE_DIR="$S" ZBUILD_PLUGIN_DIR="$TEST_TEMP_DIR/plugins/agent/judge" \
        answers_prompt_block "$P" 2>/dev/null)"
assert_contains "[A3] the opener sees its own earlier finding" "$_b3" "judge finding 1 (opened by judge): the issue asks for a dry run"
assert_contains "[A3] and is asked whether it is satisfied" "$_b3" "satisfied —"

R=$'some prose\nANSWER acceptance-gate finding 1: nothing to do — the wiring file is a design choice\nANSWER acceptance-gate finding 2: done — SPEC-3s test now checks the event is emitted\nANSWER acceptance-gate finding 3: maybe later\nnot an answer line'
_j="$(ZBUILD_CURRENT_STAGE=test-author answers_parse "$R" 2>/dev/null)"
assert_eq "[A4] finding 1's answer" "nothing to do" "$(jq -r '.["acceptance-gate finding 1"].answer // empty' <<< "$_j" 2>/dev/null)"
assert_eq "[A4] finding 2's answer" "done" "$(jq -r '.["acceptance-gate finding 2"].answer // empty' <<< "$_j" 2>/dev/null)"
assert_contains "[A4] the why is kept" "$(jq -r '.["acceptance-gate finding 2"].why // empty' <<< "$_j" 2>/dev/null)" "now checks the event is emitted"
assert_eq "[A4] who answered is recorded" "test-author" "$(jq -r '.["acceptance-gate finding 1"].by // empty' <<< "$_j" 2>/dev/null)"
assert_eq "[A4] a malformed answer is ignored" "absent" "$(jq -r 'if has("acceptance-gate finding 3") then "present" else "absent" end' <<< "$_j" 2>/dev/null)"

_s1="$(ZBUILD_CURRENT_STAGE=build answers_parse $'ANSWER acceptance-gate finding 1: satisfied — looks fine' 2>/dev/null)"
assert_eq "[A5] satisfied from another stage does not count" "absent" \
    "$(jq -r 'if has("acceptance-gate finding 1") then "present" else "absent" end' <<< "$_s1" 2>/dev/null)"
_s2="$(ZBUILD_CURRENT_STAGE=acceptance-gate answers_parse $'ANSWER acceptance-gate finding 1: satisfied — the file now calls it' 2>/dev/null)"
assert_eq "[A5] satisfied from the opener counts" "satisfied" "$(jq -r '.["acceptance-gate finding 1"].answer // empty' <<< "$_s2" 2>/dev/null)"

# A6: through the router's one funnel for every model call.
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh" >/dev/null 2>&1 || true
cp "$P" "$TEST_TEMP_DIR/p6.txt"
( export ZBUILD_CURRENT_STAGE=build ZBUILD_STATE_DIR="$S"
  _route_answers_append "$TEST_TEMP_DIR/p6.txt"; _route_answers_append "$TEST_TEMP_DIR/p6.txt" ) >/dev/null 2>&1
assert_eq "[A6] the router appends the block once" "1" "$(grep -c 'Answer every finding' "$TEST_TEMP_DIR/p6.txt" 2>/dev/null || true)"

# A7: the prompt a stage writes holds no findings; they arrive with the stage
# summaries the funnel adds. The summary renderer is stubbed to its real
# heading and line shapes — what is under test is the funnel's order.
S7="$TEST_TEMP_DIR/state7"; mkdir -p "$S7"
printf '{"schema_version":1}\n' > "$S7/pipeline-state.json"
printf 'Do your task.\n' > "$TEST_TEMP_DIR/p7.txt"
SNAP7="$TEST_TEMP_DIR/p7.snap"
(
    # shellcheck source=../../core/pipeline/input-resolve.sh
    source "$REPO_ROOT/core/pipeline/input-resolve.sh" >/dev/null 2>&1
    stage_summaries_prompt_block() {
        printf '%s\n' "=== STAGE SUMMARIES ===" \
            "### test (verdict: fail) — its findings, to answer" \
            "- test finding 1 (opened by test): run-tests-test.sh fails on line 40"
    }
    stage_summaries_count() { printf '1 1\n'; }
    apply_scope_redaction() { cp "$1" "$SNAP7"; cp "$1" "$2"; return 0; }
    export ZBUILD_CURRENT_STAGE=build ZBUILD_STATE_DIR="$S7"
    unset ZBUILD_PLUGIN_DIR ZBUILD_STAGE_INPUTS
    ZBUILD_SCOPE_MANIFEST="$TEST_TEMP_DIR/m7.yaml"; : > "$ZBUILD_SCOPE_MANIFEST"
    _route_redact_prompt "$TEST_TEMP_DIR/p7.txt" "$TEST_TEMP_DIR/p7.out" 0 ""
) >/dev/null 2>&1
_p7="$(cat "$SNAP7" 2>/dev/null)"
assert_contains "[A7] the funnel added the summaries (fixture live)" "$_p7" "- test finding 1 (opened by test)"
assert_contains "[A7] and asked for an answer to them, before redaction" "$_p7" "Answer every finding"
_ln_f="$(grep -n -- '- test finding 1' "$SNAP7" 2>/dev/null | cut -d: -f1)"
_ln_a="$(grep -n 'Answer every finding' "$SNAP7" 2>/dev/null | cut -d: -f1)"
if [[ -n "$_ln_f" && -n "$_ln_a" && "$_ln_a" -gt "$_ln_f" ]]; then
    assert_pass "[A7] the request comes after the findings it asks about"
else
    assert_fail "[A7] the request comes after the findings it asks about" "finding line ${_ln_f:-none}, request line ${_ln_a:-none}"
fi

# A8: markdown around an answer line (#2322). The first line is design's reply
# from #2032 run 37289606005, verbatim.
_m="$(ZBUILD_CURRENT_STAGE=design answers_parse "$(cat <<'EOF'
**ANSWER spec-correspondence finding 1:** done — SPEC-5 no longer claims ordering
**ANSWER spec-correspondence finding 2**: nothing to do — the wiring is already in the plan
`ANSWER spec-correspondence finding 3: done — split SPEC-2`
- ANSWER spec-correspondence finding 4: Nothing To Do — not mine
* ANSWER spec-correspondence finding 5: DONE — renamed the test
> ANSWER spec-correspondence finding 6: done — quoted
**ANSWER spec-correspondence:** done — no finding number
- the spec-correspondence finding 8 is done — prose, not an answer
EOF
)" 2>/dev/null)"
_ans() { jq -r --arg k "spec-correspondence finding $1" '.[$k].answer // "absent"' <<< "$_m" 2>/dev/null; }
assert_eq "[A8] bold, colon inside the bold" "done" "$(_ans 1)"
assert_contains "[A8] ...and the why is kept, without the markdown" \
    "$(jq -r '.["spec-correspondence finding 1"].why // empty' <<< "$_m" 2>/dev/null)" "SPEC-5 no longer claims ordering"
assert_eq "[A8] bold, colon outside the bold" "nothing to do" "$(_ans 2)"
assert_eq "[A8] inline code" "done" "$(_ans 3)"
assert_eq "[A8] a leading '- ', answer word in mixed case" "nothing to do" "$(_ans 4)"
assert_eq "[A8] a leading '* ', answer word in capitals" "done" "$(_ans 5)"
assert_eq "[A8] a leading '> '" "done" "$(_ans 6)"
assert_eq "[A8] markdown does not excuse a line without the finding shape" "1" \
    "$(jq -r '[keys[] | select(test("finding [0-9]+$") | not)] | length + 1' <<< "$_m" 2>/dev/null)"
assert_eq "[A8] prose that mentions a finding is not an answer" "absent" "$(_ans 8)"

# A9: one vocabulary — not reproduced is a reason for nothing to do (#2322).
_n="$(ZBUILD_CURRENT_STAGE=build answers_parse "$(cat <<'EOF'
ANSWER test finding 1: NOT_REPRODUCED — tests/unit/a-test.sh passes on this tree
- ANSWER test finding 2: nothing to do — not reproduced: tests/unit/b-test.sh
ANSWER test finding 3: not reproduced: tests/unit/c-test.sh
EOF
)" 2>/dev/null)"
assert_eq "[A9] NOT_REPRODUCED is recorded as nothing to do" "nothing to do" \
    "$(jq -r '.["test finding 1"].answer // "absent"' <<< "$_n" 2>/dev/null)"
assert_contains "[A9] ...and keeps the reason" \
    "$(jq -r '.["test finding 1"].why // empty' <<< "$_n" 2>/dev/null)" "tests/unit/a-test.sh passes on this tree"
assert_eq "[A9] nothing to do — not reproduced: <path> is nothing to do" "nothing to do" \
    "$(jq -r '.["test finding 2"].answer // "absent"' <<< "$_n" 2>/dev/null)"
assert_contains "[A9] ...and keeps the path" \
    "$(jq -r '.["test finding 2"].why // empty' <<< "$_n" 2>/dev/null)" "not reproduced: tests/unit/b-test.sh"
assert_eq "[A9] 'not reproduced:' on its own is nothing to do" "nothing to do" \
    "$(jq -r '.["test finding 3"].answer // "absent"' <<< "$_n" 2>/dev/null)"
assert_contains "[A9] ...and keeps the path" \
    "$(jq -r '.["test finding 3"].why // empty' <<< "$_n" 2>/dev/null)" "tests/unit/c-test.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
