#!/usr/bin/env bash
# tests/unit/no-change-handoff-test.sh — a try that changed nothing hands its
# findings on instead of repeating itself (#2565 part 4; ADR-054 §6a, ADR-068
# §6, ADR-071 §1).
#
# Why: on #1764 run 44090911022 test-author's tries 2 and 3 changed no file and
# answered "wrong" to the same finding of its own check, in both rounds; the
# finding was really design's (DSCLA-10's Given), and design was never told.
#
# H1 [guard]  an unusable try that changed nothing, with the same findings, is
#             not tried again
# H2 [change] its `wrong` answers reach the stage's output marked `handoff:`,
#             of that output's topic, with the finding and the answer's why; the
#             result ends the round (ends_round), as test-author's untestable
#             path does
# H3 [change] `not mine` is handed on the same way
# H4 [change] `done` with nothing changed is a finding back to the stage, in its
#             own result; nothing is handed on and the round does not end
# H5 [change] the last try the budget allows hands on too (retry: 1)
# H10 [change] (review) a halting outcome (misconfigured) hands nothing on and
#             ends no round
# H11 [change] (review) a wrong to another stage's finding is not handed on
# H6 [guard]  a try that changed something hands nothing on; [change] the
#             handed-on file of an earlier run of the stage is gone when it
#             runs again
# H7 [change] test-author declares a handoff output of topic design-findings
#             (#2569), and design is shown what test-author hands on there
# H8 [change] the shared answer rules say done is for what the stage changed
#             in this round, in this try or an earlier one (#2627: on #1722 run
#             45872552515 build's second try answered nine findings its first
#             try had fixed "wrong — not reproduced"); already right is wrong;
#             someone else's is not mine
# H12 [change] (#2627) a try that changed nothing after an earlier try of the
#             stage that did: its `done` stands — no finding back — and its
#             `wrong` is still handed on
# H9 [change] stage.findings.handed_on is announced, and is a known event
# H13 [change] (#2627, ADR-068 §8; review) a stage run again after a try that
#             timed out, through the engine's own retry, sees that try's
#             outcome in its own section's header; its first try sees the
#             verdict the engine recorded
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
print_test_header "a try that changed nothing hands its findings on (#2565)"
setup_test_env "no-change-handoff"

export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR"
unset ZBUILD_CYCLE_ITER ZBUILD_DISPOSITION_REDISPATCH

TPL="$TEST_TEMP_DIR/t.yaml"
cat > "$TPL" <<'YAML'
id: t
name: handoff
defaults:
  strategy: fanout
flow:
  - ans
ans:
  roles: [answerer]
  retry: 2
once:
  roles: [answerer]
  retry: 1
YAML
load_template "$TPL" >/dev/null 2>&1

# A stage whose result holds one finding of its own and the answer in $ANSWER;
# it ends with the next word of $OUTCOMES (the last repeats) and changes its
# work file only when SAME is not 1.
P="$TEST_TEMP_DIR/plugins/agent/answerer"; mkdir -p "$P"
cat > "$P/manifest.yaml" <<'MF'
id: answerer
name: Answerer
kind: agent
version: 0.0.1
hooks:
  run: answerer_run
provides:
  role: answerer
  result_contract: 3
outputs:
  - id: answerer_result
    topic: test-findings
    path: ${artifact_dir}/answerer-result.json
    type: json
    required: true
    primary: true
  - id: answerer_work
    path: ${artifact_dir}/answerer-work.txt
    type: text
    required: false
  - id: answerer_handoff
    topic: design-findings
    path: ${artifact_dir}/answerer-design-result.json
    type: routed-findings.json@1
    required: false
    handoff: true
MF
cat > "$P/plugin.sh" <<'PL'
answerer_run() {
    local art; art="$(dirname "$2")/artifacts"; mkdir -p "$art"
    local n=0; [[ -f "$art/runs.$1" ]] && n="$(cat "$art/runs.$1")"
    n=$(( n + 1 )); printf '%s' "$n" > "$art/runs.$1"
    local -a w=(${OUTCOMES:-pass}); local i=$(( n - 1 ))
    (( i >= ${#w[@]} )) && i=$(( ${#w[@]} - 1 ))
    if [[ "${SAME:-0}" == "1" ]]; then printf 'same' > "$art/answerer-work.txt"
    elif [[ "${FIRST:-0}" == "1" ]]; then (( n == 1 )) && printf 'run 1' > "$art/answerer-work.txt"
    else printf 'run %s' "$n" > "$art/answerer-work.txt"; fi
    # H13: the Previous work this try is shown, as its own header reads it.
    if [[ -n "${PW_OUT:-}" ]]; then
        _TPL_STAGES=("$1"); _stage_block_previous_work "$1" "$(dirname "$2")" "$PW_ROOT" \
            "$(_inputs_resolve_stage "$1" "$PW_ROOT" "$(dirname "$2")")" "$(dirname "$2")" > "$PW_OUT.$n" 2>/dev/null
    fi
    source "@RESULT_LIB@"
    stage_result_write "$art/answerer-result.json" "${w[$i]}" "1 finding open" \
        "$(jq -nc --arg a "${ANSWER:-}" '{findings: [{n: 1, text: "SPEC-3: the assertion does not test its Given"}]}
            + (if $a == "" then {} else {answers: [$a]} end)')"
    [[ "${w[$i]}" == pass || "${w[$i]}" == fail ]] && return 0
    return 1
}
PL
sed -i.bak "s|@RESULT_LIB@|$REPO_ROOT/scripts/lib/stage-result.sh|" "$P/plugin.sh"

S="$TEST_TEMP_DIR/state"; A="$S/artifacts"; mkdir -p "$A"
printf '{"schema_version":1}' > "$S/pipeline-state.json"
export ZBUILD_STATE_DIR="$S" ZBUILD_ARTIFACT_DIR="$A"

# _same — a clean slate whose work file already holds what an unchanged try writes.
_same() { rm -rf "$A" "$S/runtime"; mkdir -p "$A"; printf 'same' > "$A/answerer-work.txt"; : > "$ZBUILD_EVENTS_JSONL"; }
_runs() { cat "$A/runs.$1" 2>/dev/null || echo 0; }
_dispatch() { plugin_hook_call "$P" run "$1" "$S/pipeline-state.json" >/dev/null 2>&1; }
_handed() { jq -r '[.data.findings[]?.text] | join("\n")' "$A/answerer-design-result.json" 2>/dev/null; }
_ends() { jq -r '.data.ends_round // false' "$A/answerer-result.json" 2>/dev/null; }

WRONG="ans finding 1: wrong — the Given cannot be met by any test; design must rewrite SPEC-3"
NOTMINE="ans finding 1: not mine — design owns SPEC-3's Given"
DONE="ans finding 1: done — rewrote the assertion"

# ── H1 / H2 ──────────────────────────────────────────────────────────────────
_same; SAME=1 OUTCOMES="unusable" ANSWER="$WRONG" _dispatch ans
assert_eq "[H1] an unusable try that changed nothing, the same findings, is not tried again" "2" "$(_runs ans)"
_h="$(_handed)"
assert_contains "[H2] the wrong answer reaches the stage's handoff output" "$_h" "design must rewrite SPEC-3"
assert_contains "[H2] ...with the finding it answers" "$_h" "the assertion does not test its Given"
assert_contains "[H2] ...naming the stage and its answer" "$_h" "ans changed nothing for ans finding 1 and answered: wrong"
assert_eq "[H2] the handed-on output holds one finding, numbered" "1" "$(jq -r '.data.findings[0].n' "$A/answerer-design-result.json" 2>/dev/null)"
assert_eq "[H2] the handed-on output has no verdict of its own" "null" "$(jq -r '.verdict // .outcome // null' "$A/answerer-design-result.json" 2>/dev/null)"
assert_eq "[H2] the stage's result ends the round" "true" "$(_ends)"
assert_contains "[H2] ...which the loop reads from the stage's report" "$(_verdict_report_from_file "$A/answerer-result.json")" '"ends_round":true'

# ── H3 ───────────────────────────────────────────────────────────────────────
_same; SAME=1 OUTCOMES="unusable" ANSWER="$NOTMINE" _dispatch ans
assert_contains "[H3] a not-mine answer is handed on" "$(_handed)" "design owns SPEC-3's Given"
assert_eq "[H3] ...and ends the round" "true" "$(_ends)"

# ── H4 ───────────────────────────────────────────────────────────────────────
_same; SAME=1 OUTCOMES="unusable" ANSWER="$DONE" _dispatch ans
assert_eq "[H4] done with nothing changed hands nothing on" "absent" "$([[ -e "$A/answerer-design-result.json" ]] && echo present || echo absent)"
assert_eq "[H4] ...and does not end the round" "false" "$(_ends)"
_own="$(jq -r '[.data.findings[]?.text] | join("\n")' "$A/answerer-result.json" 2>/dev/null)"
assert_contains "[H4] it is a finding back to the stage, in its own result" "$_own" "answered done, but this try changed nothing"
assert_contains "[H4] ...naming the finding it answered" "$_own" "ans finding 1"
assert_eq "[H4] ...numbered after the stage's own" "1 2" "$(jq -r '[.data.findings[]?.n] | map(tostring) | join(" ")' "$A/answerer-result.json" 2>/dev/null)"

# ── H5 ───────────────────────────────────────────────────────────────────────
_same; SAME=1 OUTCOMES="unusable" ANSWER="${WRONG/#ans /once }" _dispatch once
assert_eq "[H5] retry: 1 runs twice" "2" "$(_runs once)"
assert_contains "[H5] ...and its last try, changing nothing, hands on" "$(_handed)" "design must rewrite SPEC-3"

# ── H6 ───────────────────────────────────────────────────────────────────────
# Every try changes its work and fails: the budget runs out, nothing is handed on.
_same; OUTCOMES="unusable" ANSWER="$WRONG" _dispatch ans
assert_eq "[H6] a try that changed something hands nothing on" "absent" "$([[ -e "$A/answerer-design-result.json" ]] && echo present || echo absent)"
assert_eq "[H6] ...and its round goes on" "false" "$(_ends)"
# ── H12 ──────────────────────────────────────────────────────────────────────
_same; FIRST=1 OUTCOMES="unusable" ANSWER="$DONE" _dispatch ans
assert_eq "[H12] try 1 changed its work, try 2 nothing: two tries" "2" "$(_runs ans)"
assert_eq "[H12] its done stands: its result holds only its own finding, none sent back" "1" \
    "$(jq -r '[.data.findings[]?.n] | map(tostring) | join(" ")' "$A/answerer-result.json" 2>/dev/null)"
_same; FIRST=1 OUTCOMES="unusable" ANSWER="$WRONG" _dispatch ans
assert_contains "[H12] ...and its wrong is still handed on" "$(_handed)" "design must rewrite SPEC-3"
# ── H10 / H11 (review on #2565) ──────────────────────────────────────────────
_same; SAME=1 OUTCOMES="misconfigured" ANSWER="$WRONG" _dispatch ans
assert_eq "[H10] a halting outcome hands nothing on" "absent" "$([[ -e "$A/answerer-design-result.json" ]] && echo present || echo absent)"
assert_eq "[H10] ...and ends no round, so it halts" "false" "$(_ends)"
_same; SAME=1 OUTCOMES="unusable" ANSWER="build finding 2: wrong — the test is right" _dispatch ans
assert_eq "[H11] a wrong to another stage's finding is not handed on (it goes back to that judge)" "absent" \
    "$([[ -e "$A/answerer-design-result.json" ]] && echo present || echo absent)"
assert_eq "[H11] ...and ends no round" "false" "$(_ends)"
_same; SAME=1 OUTCOMES="unusable" ANSWER="$WRONG" _dispatch ans
rm -f "$A/runs.ans"; OUTCOMES="pass" ANSWER="" _dispatch ans
assert_eq "[H6] the handed-on file of an earlier run is gone when the stage runs again" "absent" "$([[ -e "$A/answerer-design-result.json" ]] && echo present || echo absent)"

# ── H9 ───────────────────────────────────────────────────────────────────────
_same; SAME=1 OUTCOMES="unusable" ANSWER="$WRONG" _dispatch ans
_ev="$(jq -c 'select(.type == "stage.findings.handed_on")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null)"
assert_eq "[H9] one stage.findings.handed_on" "1" "$(/usr/bin/grep -c . <<< "$_ev")"
assert_eq "[H9] ...naming the stage, how many were handed on and sent back" "ans 1 0" \
    "$(jq -r '"\(.data.stage) \(.data.handed_on) \(.data.sent_back)"' <<< "$_ev" 2>/dev/null)"
if /usr/bin/grep -q '"stage.findings.handed_on"' "$REPO_ROOT/config/event-schema.json"; then
    assert_pass "[H9] stage.findings.handed_on is a known event"
else
    assert_fail "[H9] stage.findings.handed_on is a known event" "not in config/event-schema.json"
fi

# ── H7 ───────────────────────────────────────────────────────────────────────
source "$REPO_ROOT/core/state/resume.sh"
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
source "$REPO_ROOT/scripts/lib/stage-result.sh"
PROOT="$REPO_ROOT/plugins"; S2="$TEST_TEMP_DIR/state2"; A2="$S2/artifacts"; mkdir -p "$A2"
init_state "$S2/pipeline-state.json" run-1 7 >/dev/null 2>&1
export ZBUILD_ARTIFACT_DIR="$A2" ZBUILD_STATE_DIR="$S2"
_TPL_STAGES=(design test-author build)
_ta_h="$(/usr/bin/grep -c 'handoff: true' "$PROOT/agent/test-author/manifest.yaml")"
assert_eq "[H7] test-author declares one handoff output" "1" "$_ta_h"
stage_result_write "$A2/test-author-result.json" unusable "1 finding open" \
    "$(jq -nc '{findings: [{n: 1, text: "DSCLA-10: the assertion does not test the Given"}],
                answers: ["test-author finding 1: wrong — no test can register an event; design must say what is observed"]}')"
stage_handoff_unchanged "$PROOT/agent/test-author" test-author "$S2/pipeline-state.json" >/dev/null 2>&1
assert_contains "[H7] test-author hands it on in its design-findings output" \
    "$(jq -r '[.data.findings[]?.text] | join("\n")' "$A2/test-author-design-result.json" 2>/dev/null)" "design must say what is observed"
_update_stage_status "$S2/pipeline-state.json" design complete
_update_stage_status "$S2/pipeline-state.json" test-author complete
_idx="$(_inputs_resolve_stage design "$PROOT" "$S2")"
_pw="$(_stage_block_previous_work design "$S2" "$PROOT" "$_idx" "" "$PROOT/agent/design/manifest.yaml")"
assert_contains "[H7] design is shown what test-author handed on" "$_pw" "design must say what is observed"

# ── H8 ───────────────────────────────────────────────────────────────────────
_forms="$(stage_answer_forms)"
assert_contains "[H8] done is for what the stage changed in this round, in any try" "$_forms" "Answer done for what this stage changed for it in this round, in this try or an earlier one"
assert_contains "[H8] ...and an earlier try's change is said to be one" "$_forms" "when an earlier try made the change, say so"
if grep -qF "only for what you changed in this call" <<< "$_forms"; then assert_fail "[H8] ...not only this call" "$_forms"
else assert_pass "[H8] ...not only this call"; fi
assert_contains "[H8] already right is wrong, and why" "$_forms" "If the finding needs no change because your output is already right, answer wrong, and say why."
assert_contains "[H8] someone else's is not mine, and who" "$_forms" "If someone else must change something, answer not mine, and say who."

# ── H13 (review on #2627, ADR-068 §8) ─────────────────────────────────────────
print_test_section "H13: a try after one that timed out sees that try's outcome as its own"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh" 2>/dev/null || true
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh" >/dev/null 2>&1 || true
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
_same
# The engine's record from the stage's last finish: it passed.
_update_stage_status "$S/pipeline-state.json" ans complete >/dev/null 2>&1
_zbuild_state_set_stage_verdict "$S/pipeline-state.json" ans pass >/dev/null 2>&1
PW_OUT="$TEST_TEMP_DIR/pw" PW_ROOT="$TEST_TEMP_DIR/plugins" OUTCOMES="timed_out pass" ANSWER="" _dispatch ans
assert_eq "[H13] try 1 timed out and was run again" "2" "$(_runs ans)"
assert_contains "[H13] try 2's own header gives try 1's outcome" "$(cat "$TEST_TEMP_DIR/pw.2" 2>/dev/null)" "(verdict: timed_out) — your own"
assert_contains "[H13] try 1's gives the verdict the engine recorded" "$(cat "$TEST_TEMP_DIR/pw.1" 2>/dev/null)" "(verdict: pass) — your own"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
