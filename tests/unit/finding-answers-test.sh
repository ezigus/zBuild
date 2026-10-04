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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
