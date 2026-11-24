#!/usr/bin/env bash
# tests/unit/stage-takes-topics-test.sh — each output says what it is about
# (its topic); each stage says which topics it takes; Previous work holds only
# those (ADR-071).
#
# #1944 run 40393999128: design's second round was handed the test stage's
# failing files, their logs and every code finding, and spent its whole call
# debugging them instead of revising the design.
#
#   T1 [change]: a stage that declares takes: sees the outputs, summaries,
#                findings and errors of those topics — and nothing of the others
#   T2 [change]: an output with no topic reaches no stage that declares takes:
#   T3 [guard] : a stage with no takes: still sees every stage's output
#   T4 [change]: the line naming the files the work changed is a `change` —
#                shown only to a stage that takes change
#   T5 [guard] : a stage's own notes always come back to it
#   T6 [change]: a manifest naming a topic or a take outside the six is
#                refused at load, naming the word
#   T7 [change]: the shipped stages — each model stage's takes:, and every
#                output of the shipped stages has a topic from the six (#2569)
#   T8 [change]: the dispatch passes the stage's own manifest, so its takes:
#                apply (stage_blocks_write_v)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
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

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then
        assert_fail "$1" "output unexpectedly has: $3"
    else
        assert_pass "$1"
    fi
}

print_test_header "a stage takes only the topics it names (ADR-071)"
setup_test_env "stage-takes-topics"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true

PROOT="$TEST_TEMP_DIR/plugins"
STATE="$TEST_TEMP_DIR/state"
ART="$STATE/artifacts"
mkdir -p "$ART"

# _producer <name> <topic|""> — a stage with a result (findings) and a summary,
# both of <topic>, and an error log; "" declares no topic.
_producer() {
    local s="$1" t="$2" u="${1//-/_}" tl=""
    [[ -n "$t" ]] && tl="    topic: $t"
    mkdir -p "$PROOT/tool/$s"
    {
        printf 'id: %s\nname: %s\nkind: tool\nversion: 0.0.1\nhooks:\n  run: x_run\noutputs:\n' "$s" "$s"
        printf '  - id: %s_result\n    path: ${artifact_dir}/%s-result.json\n    type: json\n    required: true\n    primary: true\n' "$u" "$s"
        [[ -n "$tl" ]] && printf '%s\n' "$tl"
        printf '  - id: %s_summary\n    path: ${artifact_dir}/%s-summary.md\n    type: text\n    required: false\n    summary: true\n' "$u" "$s"
        [[ -n "$tl" ]] && printf '%s\n' "$tl"
        printf '  - id: %s_errors\n    path: ${artifact_dir}/%s-errors.log\n    type: text\n    required: false\n    errors: true\n' "$u" "$s"
        [[ -n "$tl" ]] && printf '%s\n' "$tl"
    } > "$PROOT/tool/$s/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$PROOT/tool/$s/plugin.sh"
    stage_result_write "$ART/$s-result.json" fail fixture \
        "{\"findings\":[{\"n\":1,\"text\":\"FINDING-OF-$s\"}]}"
    printf 'SUMMARY-OF-%s\n' "$s" > "$ART/$s-summary.md"
    printf 'ERRORS-OF-%s\n' "$s" > "$ART/$s-errors.log"
    _update_stage_status "$STATE/pipeline-state.json" "$s" complete
    _zbuild_state_set_stage_verdict "$STATE/pipeline-state.json" "$s" fail
}

# _takes <topic>... — a takes: block, each take with its for: (#2428).
_takes() { local t; printf 'takes:\n'; for t in "$@"; do printf '  - topic: %s\n    for: x\n' "$t"; done; }

# _consumer <name> <takes-block|""> — a model stage; "" declares no takes:.
_consumer() {
    local s="$1" takes="$2" u="${1//-/_}"
    mkdir -p "$PROOT/agent/$s"
    {
        printf 'id: %s\nname: %s\nkind: agent\nversion: 0.0.1\n' "$s" "$s"
        [[ -n "$takes" ]] && printf '%s' "$takes"
        printf 'hooks:\n  run: x_run\noutputs:\n'
        printf '  - id: %s_result\n    path: ${artifact_dir}/%s-result.json\n    type: json\n    required: true\n    primary: true\n    topic: ask\n' "$u" "$s"
    } > "$PROOT/agent/$s/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$PROOT/agent/$s/plugin.sh"
}

init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1
_producer tt-plan ask
_producer tt-accept design-findings
_producer tt-test code-findings
_producer tt-build change
_producer tt-plumb ""
_consumer tt-design "$(_takes ask design-findings)"$'\n'
_consumer tt-any ""
_TPL_STAGES=(tt-plan tt-accept tt-test tt-build tt-plumb tt-design tt-any)

# A repository with one change on a branch, for the changed-files line.
TGT="$TEST_TEMP_DIR/target"
git init -q -b main "$TGT" && git -C "$TGT" config user.email t@t && git -C "$TGT" config user.name t
printf 'a\n' > "$TGT/a.txt"; git -C "$TGT" add a.txt; git -C "$TGT" commit -qm base
git -C "$TGT" checkout -qb work; printf 'CHANGED-FILE\n' > "$TGT/changed-file.txt"
git -C "$TGT" add changed-file.txt; git -C "$TGT" commit -qm change

# Own notes for the design consumer.
mkdir -p "$ART/notes"
printf 'MY-OWN-NOTES\n' > "$(stage_notes_path "$STATE" tt-design)"
stage_result_write "$ART/tt-design-result.json" pass fixture
_update_stage_status "$STATE/pipeline-state.json" tt-design complete

DM="$PROOT/agent/tt-design/manifest.yaml"
idx="$(_inputs_resolve_stage tt-design "$PROOT" "$STATE")"
pw="$(_stage_block_previous_work tt-design "$STATE" "$PROOT" "$idx" "$TGT" "$DM")"

print_test_section "T1: only the topics the stage takes"
assert_contains "[T1] an ask summary is shown" "$pw" "SUMMARY-OF-tt-plan"
assert_contains "[T1] a design-findings finding is shown" "$pw" "FINDING-OF-tt-accept"
assert_contains "[T1] … and its summary" "$pw" "SUMMARY-OF-tt-accept"
assert_contains "[T1] … and its errors" "$pw" "ERRORS-OF-tt-accept"
assert_not_contains "[T1] no code-findings finding" "$pw" "FINDING-OF-tt-test"
assert_not_contains "[T1] no code-findings summary" "$pw" "SUMMARY-OF-tt-test"
assert_not_contains "[T1] no code-findings errors" "$pw" "ERRORS-OF-tt-test"
assert_not_contains "[T1] no path to a code-findings output" "$pw" "$ART/tt-test-"
assert_not_contains "[T1] the stage that wrote only untaken topics is not listed" "$pw" "### tt-test"
assert_not_contains "[T1] no change summary" "$pw" "SUMMARY-OF-tt-build"

print_test_section "T2: an output with no topic"
assert_not_contains "[T2] an output with no topic reaches no stage with takes:" "$pw" "tt-plumb"

print_test_section "T4: the changed-files line is a change"
assert_not_contains "[T4] not shown to a stage that does not take change" "$pw" "changed-file.txt"

print_test_section "T5: own notes"
assert_contains "[T5] the stage's own notes come back to it" "$pw" "MY-OWN-NOTES"

print_test_section "T3: no takes: — everything"
idx2="$(_inputs_resolve_stage tt-any "$PROOT" "$STATE")"
pw2="$(_stage_block_previous_work tt-any "$STATE" "$PROOT" "$idx2" "$TGT" "$PROOT/agent/tt-any/manifest.yaml")"
assert_contains "[T3] code findings shown" "$pw2" "FINDING-OF-tt-test"
assert_contains "[T3] an output with no topic shown" "$pw2" "SUMMARY-OF-tt-plumb"
assert_contains "[T3] the changed-files line shown" "$pw2" "changed-file.txt"
pw3="$(_stage_block_previous_work tt-any "$STATE" "$PROOT" "$idx2" "$TGT")"
assert_contains "[T3] with no manifest passed, the stage's own is looked up (no takes: → all)" "$pw3" "FINDING-OF-tt-test"

print_test_section "T4: a stage that takes change sees the line"
_consumer tt-builder "$(_takes change)"$'\n'
_TPL_STAGES+=(tt-builder)
_IR_INDEX_KEY=""; _IR_SCAN_KEY=""
idx4="$(_inputs_resolve_stage tt-builder "$PROOT" "$STATE")"
pw4="$(_stage_block_previous_work tt-builder "$STATE" "$PROOT" "$idx4" "$TGT" "$PROOT/agent/tt-builder/manifest.yaml")"
assert_contains "[T4] the changed-files line for a stage that takes change" "$pw4" "changed-file.txt"
assert_contains "[T4] … with the change summary" "$pw4" "SUMMARY-OF-tt-build"
assert_not_contains "[T4] … and not the ask summary" "$pw4" "SUMMARY-OF-tt-plan"

print_test_section "T8: the dispatch hands the stage's manifest to Previous work"
t8dir=""
stage_blocks_write_v t8dir tt-design "$STATE" "$DM" "$PROOT" "$idx" "$TGT"
assert_not_contains "[T8] the written block honours the stage's takes:" \
    "$(cat "$t8dir/previous-work.md" 2>/dev/null)" "FINDING-OF-tt-test"
assert_contains "[T8] … and still holds what it takes" \
    "$(cat "$t8dir/previous-work.md" 2>/dev/null)" "FINDING-OF-tt-accept"

print_test_section "T6: only the six topics (#2569)"
# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh" 2>/dev/null || true
# _valid <dir> <takes-line> <topic> — a manifest that passes every other check.
_valid() {
    mkdir -p "$1"
    {
        printf 'id: v\nname: v\nkind: tool\nversion: 0.0.1\n'
        [[ -n "$2" ]] && printf '%s\n' "$2"
        printf 'provides:\n  result_contract: 3\nhooks:\n  run: x_run\noutputs:\n'
        printf '  - id: v_result\n    path: ${artifact_dir}/v-result.json\n    type: json\n    required: true\n    primary: true\n    topic: %s\n    description: x\n' "$3"
    } > "$1/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$1/plugin.sh"
}
_valid "$TEST_TEMP_DIR/v-ok" "$(_takes ask tests change design-findings test-findings code-findings)" ask
out="$(validate_manifest "$TEST_TEMP_DIR/v-ok/manifest.yaml" 2>&1)"; rc=$?
assert_eq "[T6] the six words are accepted" "0" "$rc"
# #2569: the old words are gone — a manifest naming one is refused.
_valid "$TEST_TEMP_DIR/v-old" "$(_takes ask requirement-findings)" change-findings
out="$(validate_manifest "$TEST_TEMP_DIR/v-old/manifest.yaml" 2>&1)"; rc=$?
assert_eq "[T6] an old word is refused" "1" "$rc"
assert_contains "[T6] … naming it" "$out" "takes 'requirement-findings'"
assert_contains "[T6] … and the other" "$out" "topic 'change-findings'"
_valid "$TEST_TEMP_DIR/v-topic" "" everything
out="$(validate_manifest "$TEST_TEMP_DIR/v-topic/manifest.yaml" 2>&1)"; rc=$?
assert_eq "[T6] an unknown topic is refused" "1" "$rc"
assert_contains "[T6] … naming it" "$out" "topic 'everything'"
_valid "$TEST_TEMP_DIR/v-take" "$(_takes ask test-logs)" ask
out="$(validate_manifest "$TEST_TEMP_DIR/v-take/manifest.yaml" 2>&1)"; rc=$?
assert_eq "[T6] an unknown take is refused" "1" "$rc"
assert_contains "[T6] … naming it" "$out" "takes 'test-logs'"

print_test_section "T7: the shipped stages"
_takes_of() { local t; _sp_takes_v t "$REPO_ROOT/plugins/agent/$1/manifest.yaml"; t="${t# }"; t="${t% }"; printf '%s' "${t// /,}"; }
# #2569 (ADR-071 §3): each stage takes the findings it can fix — named by what must change.
assert_eq "[T7] design takes the design's findings" "ask,design-findings" "$(_takes_of design)"
assert_eq "[T7] test-author takes the tests' findings (never change)" "ask,tests,test-findings" "$(_takes_of test-author)"
assert_eq "[T7] build takes the code's findings, and the tests and how they ran" "ask,tests,change,code-findings" "$(_takes_of build)"
assert_eq "[T7] issue-acceptance takes the tests and how they ran, as evidence; no findings" "ask,change,tests" "$(_takes_of issue-acceptance)"
assert_eq "[T7] review-lens takes" "ask,change" "$(_takes_of review-lens)"
assert_eq "[T7] monitor takes" "ask,change" "$(_takes_of monitor)"

# _topics_of <manifest> — "<id>=<topic>" per output, "<id>=" when none.
_topics_of() {
    awk '/^outputs:/{f=1;next} f&&/^[a-zA-Z_]/{f=0}
         f&&/^  - id:/{ if (id!="") print id "=" t; id=$3; t="" }
         f&&/^    topic:/{ t=$2 }
         END{ if (id!="") print id "=" t }' "$1" | tr '\n' ' '
}
assert_eq "[T7] intake: every output is ask" \
    "intake_result=ask scope_manifest=ask intake_goal=ask requirements=ask intake_summary=ask " \
    "$(_topics_of "$REPO_ROOT/plugins/agent/intake/manifest.yaml")"
assert_eq "[T7] design: the design is ask, its checks are design-findings" \
    "design=ask work_steps=ask design_draft=ask design_result=design-findings design_summary=design-findings " \
    "$(_topics_of "$REPO_ROOT/plugins/agent/design/manifest.yaml")"
# #2569: test-author's check finds what a test must change: test-findings, which
# build, which may not edit a test, does not take. What a try that changed
# nothing hands on (#2565) is design-findings, for design.
assert_eq "[T7] test-author: its checker is test-findings, its handoff design-findings, what the code must fix code-findings (#2599), its list of tests is tests" \
    "test_author_result=test-findings test_author_handoff=design-findings test_author_code=code-findings test_author_summary=tests " \
    "$(_topics_of "$REPO_ROOT/plugins/agent/test-author/manifest.yaml")"
assert_eq "[T7] build: change; its answers that a test is wrong are test-findings (#2441, #2569), what design must settle design-findings (#2599)" "diff_patch=change build_summary=change build_tests=test-findings build_design=design-findings build_stage_summary=change " \
    "$(_topics_of "$REPO_ROOT/plugins/agent/build/manifest.yaml")"
# #2556 (ADR-071 §1): each result names no topic; one output per topic holds its findings.
# #2569: the suite's and the check's logs are how the tests ran: tests.
assert_eq "[T7] test: the suite's findings by topic, the acceptance check's by topic" \
    "test_errors=tests test_results= test_failures_summary= test_output_log=tests test_timing=tests test_code=code-findings test_test=test-findings acceptance_result= acceptance_design=design-findings acceptance_test=test-findings acceptance_code=code-findings acceptance_detail=tests acceptance_errors=tests " \
    "$(_topics_of "$REPO_ROOT/plugins/tool/test/manifest.yaml")"
assert_eq "[T7] issue-acceptance: one output per topic; its result and summary name none" \
    "issue_acceptance_result= issue_acceptance_summary= issue_acceptance_design=design-findings issue_acceptance_test=test-findings issue_acceptance_code=code-findings " \
    "$(_topics_of "$REPO_ROOT/plugins/agent/issue-acceptance/manifest.yaml")"
# #2491: its verdict, summary and replies reach no stage; its findings do.
assert_eq "[T7] review-lens: only its findings have a topic, one per fix: word" "lens_result= review_lens_summary= review_lens_code=code-findings review_lens_test=test-findings review_lens_design=design-findings review_lens_replies= " \
    "$(_topics_of "$REPO_ROOT/plugins/agent/review-lens/manifest.yaml")"
# Every model stage composes its prompt through stage_prompt_compose*; each one
# declares takes:.
missing=""
for p in "$REPO_ROOT"/plugins/agent/*/; do
    n="$(basename "$p")"
    grep -rqE 'stage_prompt_compose' "$p" --include='*.sh' 2>/dev/null || continue
    grep -qE '^takes:' "$p/manifest.yaml" || missing+="$n "
done
assert_eq "[T7] every stage that composes a model prompt declares takes:" "" "$missing"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
