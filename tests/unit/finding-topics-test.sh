#!/usr/bin/env bash
# tests/unit/finding-topics-test.sh — each finding can carry its own topic, so
# it reaches only the stages that can fix it (#2452, ADR-071 §1 §2).
#
# #1805 run 41378014898: issue-acceptance found six unmet requirements, five of
# them code the change had not done yet. All six sat in its result, whose topic
# is requirement-findings, so design got them all — and spent its whole call
# debugging the code, saved nothing, and the run ended.
#
#   F1 [change]: stage_findings_json reads "<topic><TAB><text>" as a finding with
#                that topic; any other line is a finding with no topic
#   F2 [change]: a finding tagged code-findings is not shown to a stage that does
#                not take code-findings, though its output's topic is taken; a
#                stage that takes code-findings sees it
#   F3 [change]: a finding tagged requirement-findings reaches design from an
#                output whose topic design does not take — that output's summary,
#                paths and errors do not
#   F4 [guard] : a finding with no topic, or a word outside the five, goes by its
#                output's topic
#   F5 [change]: issue-acceptance's [fix-code] / [fix-design] marks become the finding's
#                topic; the mark is not in the text; the prompt asks for them
#   F6 [change]: issue-acceptance's summary does not list the unmet requirements
#   F7 [change]: the acceptance check tags its code and test findings
#                code-findings; its requirement findings carry no topic
#   F8 [change]: stage_findings_lines reads a result's findings back with their
#                topics, and test's own checks use it to keep them
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then
        assert_fail "$1" "output unexpectedly has: $3"
    else
        assert_pass "$1"
    fi
}

print_test_header "each finding can carry its own topic (#2452, ADR-071)"
setup_test_env "finding-topics"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true

# ── F1 ───────────────────────────────────────────────────────────────────────
print_test_section "F1: stage_findings_json reads a topic before a tab"
_f1="$(printf 'code-findings\tthe code skips it\nplain finding\nnot-a-topic\tkept whole\n' | stage_findings_json)"
assert_eq "[F1] a tagged line has that topic" "code-findings" "$(jq -r '.[0].topic' <<< "$_f1")"
assert_eq "[F1] ...and its text without the word" "the code skips it" "$(jq -r '.[0].text' <<< "$_f1")"
assert_eq "[F1] a plain line has no topic" "null" "$(jq -r '.[1].topic' <<< "$_f1")"
assert_eq "[F1] a word outside the five is no topic" "null" "$(jq -r '.[2].topic' <<< "$_f1")"
assert_eq "[F1] ...and the line is kept whole" $'not-a-topic\tkept whole' "$(jq -r '.[2].text' <<< "$_f1")"
assert_eq "[F1] numbering is unchanged" "1 2 3" "$(jq -r '[.[].n] | map(tostring) | join(" ")' <<< "$_f1")"

# ── Previous work fixtures ───────────────────────────────────────────────────
PROOT="$TEST_TEMP_DIR/plugins"
STATE="$TEST_TEMP_DIR/state"
ART="$STATE/artifacts"
mkdir -p "$ART"
init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1

# _producer <name> <topic> <findings-json> — a stage whose result, summary and
# error log all have <topic>, its result holding <findings-json>; its result
# lets a finding name any topic (finding_topics, #2454).
_producer() {
    local s="$1" t="$2" f="$3" u="${1//-/_}"
    mkdir -p "$PROOT/tool/$s"
    {
        printf 'id: %s\nname: %s\nkind: tool\nversion: 0.0.1\nhooks:\n  run: x_run\noutputs:\n' "$s" "$s"
        printf '  - id: %s_result\n    path: ${artifact_dir}/%s-result.json\n    type: json\n    required: true\n    primary: true\n    topic: %s\n    finding_topics: ask tests change requirement-findings code-findings\n' "$u" "$s" "$t"
        printf '  - id: %s_summary\n    path: ${artifact_dir}/%s-summary.md\n    type: text\n    required: false\n    summary: true\n    topic: %s\n' "$u" "$s" "$t"
        printf '  - id: %s_errors\n    path: ${artifact_dir}/%s-errors.log\n    type: text\n    required: false\n    errors: true\n    topic: %s\n' "$u" "$s" "$t"
    } > "$PROOT/tool/$s/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$PROOT/tool/$s/plugin.sh"
    stage_result_write "$ART/$s-result.json" fail fixture "{\"findings\":$f}"
    printf 'SUMMARY-OF-%s\n' "$s" > "$ART/$s-summary.md"
    printf 'ERRORS-OF-%s\n' "$s" > "$ART/$s-errors.log"
    _update_stage_status "$STATE/pipeline-state.json" "$s" complete
    _zbuild_state_set_stage_verdict "$STATE/pipeline-state.json" "$s" fail
}
_takes() { local t; printf 'takes:\n'; for t in "$@"; do printf '  - topic: %s\n    for: x\n' "$t"; done; }
_consumer() {
    local s="$1" takes="$2" u="${1//-/_}"
    mkdir -p "$PROOT/agent/$s"
    {
        printf 'id: %s\nname: %s\nkind: agent\nversion: 0.0.1\n%s\n' "$s" "$s" "$takes"
        printf 'hooks:\n  run: x_run\noutputs:\n'
        printf '  - id: %s_result\n    path: ${artifact_dir}/%s-result.json\n    type: json\n    required: true\n    primary: true\n    topic: ask\n' "$u" "$s"
    } > "$PROOT/agent/$s/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$PROOT/agent/$s/plugin.sh"
}

# ft-accept: a requirement-findings output holding one finding for the code,
# one with no topic, and one with a word outside the five.
_producer ft-accept requirement-findings \
    '[{"n":1,"text":"CODE-NOT-DONE","topic":"code-findings"},{"n":2,"text":"DESIGN-GAP"},{"n":3,"text":"ODD-WORD","topic":"nonsense"},{"n":4,"text":"NUMBER-TOPIC","topic":7}]'
# ft-test: a code-findings output holding one finding for the design.
_producer ft-test code-findings \
    '[{"n":1,"text":"WRONG-REQUIREMENT","topic":"requirement-findings"},{"n":2,"text":"FAILING-FILE"}]'
# ft-quoted: a manifest that quotes its topic, as YAML allows.
_producer ft-quoted requirement-findings '[{"n":1,"text":"QUOTED-TOPIC-FINDING"}]'
sed -i.bak 's/topic: requirement-findings/topic: "requirement-findings"/' "$PROOT/tool/ft-quoted/manifest.yaml"
_consumer ft-design "$(_takes ask requirement-findings)"
_consumer ft-build "$(_takes ask requirement-findings code-findings)"
_consumer ft-coder "$(_takes ask code-findings)"
_TPL_STAGES=(ft-accept ft-test ft-quoted ft-design ft-build ft-coder)

_pw() {
    local idx; idx="$(_inputs_resolve_stage "$1" "$PROOT" "$STATE")"
    _stage_block_previous_work "$1" "$STATE" "$PROOT" "$idx" "" "$PROOT/agent/$1/manifest.yaml"
}
_pwd="$(_pw ft-design)"; _pwb="$(_pw ft-build)"; _pwc="$(_pw ft-coder)"

# ── F2 ───────────────────────────────────────────────────────────────────────
print_test_section "F2: a code finding does not reach a stage that does not take code-findings"
assert_not_contains "[F2] design is not shown the code finding in a requirement-findings output" "$_pwd" "CODE-NOT-DONE"
assert_contains "[F2] build, which takes code-findings, is shown it" "$_pwb" "ft-accept finding 1 (opened by ft-accept): CODE-NOT-DONE"
assert_contains "[F2] a stage taking only code-findings is shown it" "$_pwc" "CODE-NOT-DONE"
assert_not_contains "[F2] ...but not the untagged finding of the requirement-findings output" "$_pwc" "DESIGN-GAP"
assert_not_contains "[F2] ...nor that output's summary" "$_pwc" "SUMMARY-OF-ft-accept"

# ── F3 ───────────────────────────────────────────────────────────────────────
print_test_section "F3: a requirement finding reaches design from a code-findings output"
assert_contains "[F3] design is shown the requirement finding" "$_pwd" "ft-test finding 1 (opened by ft-test): WRONG-REQUIREMENT"
assert_not_contains "[F3] ...not the output's untagged finding" "$_pwd" "FAILING-FILE"
assert_not_contains "[F3] ...nor its summary" "$_pwd" "SUMMARY-OF-ft-test"
assert_not_contains "[F3] ...nor its errors" "$_pwd" "ERRORS-OF-ft-test"
assert_not_contains "[F3] ...nor a path to it" "$_pwd" "$ART/ft-test-"
assert_eq "[F3] build is shown each finding once" "1" "$(grep -c 'WRONG-REQUIREMENT' <<< "$_pwb")"

# ── F4 ───────────────────────────────────────────────────────────────────────
print_test_section "F4: no topic, or a word outside the five, goes by the output's topic"
assert_contains "[F4] design is shown the untagged finding of a requirement-findings output" "$_pwd" "DESIGN-GAP"
assert_contains "[F4] ...and the one whose word is not a topic" "$_pwd" "ODD-WORD"
assert_contains "[F4] ...and one whose topic is not a word at all" "$_pwd" "NUMBER-TOPIC"
assert_contains "[F4] an output whose manifest quotes its topic goes by that topic" "$_pwd" "QUOTED-TOPIC-FINDING"
assert_contains "[F4] ...and that output's summary" "$_pwd" "SUMMARY-OF-ft-accept"
assert_not_contains "[F4] a stage not taking requirement-findings is not shown the odd word" "$_pwc" "ODD-WORD"
assert_contains "[F4] it is shown the untagged finding of a code-findings output" "$_pwc" "FAILING-FILE"

# ── F5 / F6 ──────────────────────────────────────────────────────────────────
PLUGIN_DIR="$REPO_ROOT/plugins/agent/issue-acceptance"
# The engine's blocks, as setup_test_env made them (unset above for Previous work).
export ZBUILD_STAGE_BLOCKS="$TEST_TEMP_DIR/stage-blocks"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$PLUGIN_DIR/plugin.sh" 2>/dev/null
set +e
_IA_ANSWER=""
route_to_model() { printf '%s\n' "$_IA_ANSWER"; return 0; }
resolve_tier() { printf 'T2'; }
_ia_setup() {
    _S="$TEST_TEMP_DIR/$1"; _A="$_S/artifacts"; local _in="$_S/inputs"
    mkdir -p "$_A" "$_in"
    printf '{}' > "$_S/pipeline-state.json"
    zb_test_issue_output "$_in" "Do it. Acceptance: - [ ] resume skips done stages" >/dev/null
    printf '%s\n' '# Design' '```acceptance' 'SPEC-1[code]: resume skips' 'TESTFILES:' 'SPEC-1: tests/t.sh' 'WIRING: none' '```' > "$_in/design.md"
    printf '%s\n' 'diff --git a/p.sh b/p.sh' '+x=1' > "$_in/diff.patch"
    zb_test_test_run_output "$_in" fail 1 1 >/dev/null
    jq -n --arg i "$_in/intake-result.json" --arg d "$_in/design.md" --arg p "$_in/diff.patch" --arg t "$_in/test-results.json" \
        '{inputs: {a: $i, b: $d, c: $p, d: $t}}' > "$_S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$_S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$_A"
}
_ia_res() { jq -r "$1" "$_A/issue-acceptance-result.json" 2>/dev/null || echo MISSING; }

print_test_section "F5: issue-acceptance's marks become the finding's topic"
_ia_setup f5
# #2464 (ADR-072 §3): each complaint quoted.
_IA_ANSWER=$'UNMET: [fix-code] resume | WHY: intake still runs on resume | QUOTE: "resume skips done stages"\nUNMET: [fix-design] the design | WHY: the design never says only on a resume | QUOTE: "resume skips done stages"\nUNMET: the rest | WHY: unmarked | QUOTE: "Do it."'
issue_acceptance_run issue-acceptance "$_S/pipeline-state.json" >/dev/null 2>&1
assert_eq "[F5] [fix-code] → code-findings" "code-findings" "$(_ia_res '.data.findings[0].topic')"
assert_eq "[F5] [fix-design] → requirement-findings" "requirement-findings" "$(_ia_res '.data.findings[1].topic')"
assert_eq "[F5] an unmarked line has no topic" "null" "$(_ia_res '.data.findings[2].topic')"
assert_eq "[F5] the mark is not in data.unmet" 'resume: intake still runs on resume — "resume skips done stages"' "$(_ia_res '.data.unmet[0]')"
assert_not_contains "[F5] ...nor in the finding" "$(_ia_res '.data.findings[0].text')" "[fix-code]"
assert_contains "[F5] the finding names the requirement" "$(_ia_res '.data.findings[0].text')" "resume: intake still runs on resume"
_p5="$(tr -s '[:space:]' ' ' <<< "$(_ia_prompt I S D fail)")"
assert_contains "[F5] the prompt asks for the [fix-code] mark" "$_p5" "[fix-code]"
assert_contains "[F5] the prompt asks for the [fix-design] mark" "$_p5" "[fix-design]"

print_test_section "F6: issue-acceptance's summary does not list the unmet requirements"
_sum="$(cat "$_A/issue-acceptance-summary.md" 2>/dev/null)"
assert_not_contains "[F6] no unmet requirement in the summary" "$_sum" "intake still runs on resume"
assert_not_contains "[F6] ...nor the design one" "$_sum" "the design never says"
assert_contains "[F6] the summary counts them" "$_sum" "3 requirement(s) not met"

# ── F7 ───────────────────────────────────────────────────────────────────────
print_test_section "F7: the acceptance check tags its code and test findings"
# shellcheck source=../../plugins/tool/test/lib/acceptance-reason.sh
source "$REPO_ROOT/plugins/tool/test/lib/acceptance-reason.sh"
_f7="$(_ag_reason_findings_json not_passing_at_head:SPEC-2 tautology:SPEC-1 untested_change:lib/a.sh \
        unreached_at_head:SPEC-4 killed_by_signal:SPEC-5 negctl_error:timeout:SPEC-6 inert_wiring:lib/w.sh 2>/dev/null)"
_topic_of() { jq -r --arg k "$1" '[.[] | select(.text | contains($k)) | .topic][0]' <<< "$_f7"; }
assert_eq "[F7] a test failing on the new code → code-findings" "code-findings" "$(_topic_of 'does not pass on the new code')"
assert_eq "[F7] a changed file no test checks → code-findings" "code-findings" "$(_topic_of 'no test checks what this change does')"
assert_eq "[F7] a test that never reached its assertion → code-findings" "code-findings" "$(_topic_of 'never ran on the new code')"
assert_eq "[F7] a test file that died on a signal → code-findings" "code-findings" "$(_topic_of 'died on a signal')"
assert_eq "[F7] a test file too slow to check → code-findings" "code-findings" "$(_topic_of 'ran past its time limit')"
assert_eq "[F7] a test that passes on the old code → no topic" "null" "$(_topic_of 'already passes on the code from before')"
assert_eq "[F7] a WIRING finding → no topic" "null" "$(_topic_of 'is not what runs the new behaviour')"
assert_eq "[F7] one finding per kind of problem" "7" "$(jq 'length' <<< "$_f7")"
_r7="$(_ag_build_reason not_passing_at_head:SPEC-2 tautology:SPEC-1 2>/dev/null)"
assert_not_contains "[F7] the reason carries no topic word" "$_r7" "code-findings"
assert_contains "[F7] the gate writes these findings" "$(cat "$REPO_ROOT/plugins/tool/test/lib/acceptance-check.sh")" "_ag_reason_findings_json"

# ── F8 ───────────────────────────────────────────────────────────────────────
print_test_section "F8: a result's findings read back with their topics"
_f8="$(stage_findings_lines "$ART/ft-accept-result.json" | stage_findings_json)"
assert_eq "[F8] the tagged finding keeps its topic" "code-findings" "$(jq -r '.[0].topic' <<< "$_f8")"
assert_eq "[F8] ...and its text" "CODE-NOT-DONE" "$(jq -r '.[0].text' <<< "$_f8")"
assert_eq "[F8] the untagged one stays untagged" "null" "$(jq -r '.[1].topic' <<< "$_f8")"
assert_eq "[F8] a word outside the five is dropped" "null" "$(jq -r '.[2].topic' <<< "$_f8")"
assert_eq "[F8] ...keeping the text alone" "ODD-WORD" "$(jq -r '.[2].text' <<< "$_f8")"
assert_eq "[F8] a topic that is not a word is dropped too" "NUMBER-TOPIC" "$(jq -r '.[3].text' <<< "$_f8")"
assert_contains "[F8] test's own checks read findings back with it" \
    "$(cat "$REPO_ROOT/plugins/tool/test/lib/own-checks.sh")" "stage_findings_lines"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
