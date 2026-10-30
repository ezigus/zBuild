#!/usr/bin/env bash
# tests/unit/stage-contract-card-test.sh — each stage states its contract in its
# own manifest, and every finding a stage takes reaches it (#2428, ADR-071).
#
# #1951 run 40977129600: the acceptance check's finding ("write WIRING: none")
# sat in test's acceptance-gate-result.json (requirement-findings), but Previous
# work read findings only from test's primary output (code-findings). Design
# takes requirement-findings and never saw it.
#
#   C1 [change]: a take is { topic, for }; validate_manifest refuses a take with
#                no for:, an unknown topic, and the old one-line form
#   C2 [change]: an output that names a topic has a description:
#   C3 [change]: Previous work reads the topics from the new form
#   C4 [change]: the findings of every taken output reach the stage, labelled
#                by the output they are in; an untaken output's never do
#   C5 [change]: every shipped stage's take has a for:, every output with a
#                topic a description:
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
# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh" 2>/dev/null || true

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then
        assert_fail "$1" "output unexpectedly has: $3"
    else
        assert_pass "$1"
    fi
}

print_test_header "each stage states its contract; every finding it takes reaches it (#2428)"
setup_test_env "stage-contract-card"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true

# _card <dir> <takes-block> <output-extra> — a manifest that passes every other check.
_card() {
    mkdir -p "$1"
    {
        printf 'id: v\nname: v\nkind: tool\nversion: 0.0.1\n'
        [[ -n "$2" ]] && printf '%s\n' "$2"
        printf 'provides:\n  result_contract: 3\nhooks:\n  run: x_run\noutputs:\n'
        printf '  - id: v_result\n    path: ${artifact_dir}/v-result.json\n    type: json\n    required: true\n    primary: true\n'
        [[ -n "$3" ]] && printf '%s\n' "$3"
    } > "$1/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$1/plugin.sh"
}
_DESC='    topic: ask
    description: the result'

print_test_section "C1: a take is { topic, for }"
_card "$TEST_TEMP_DIR/c1-ok" 'takes:
  - topic: ask
    for: the issue to work from
  - topic: requirement-findings
    for: findings about the requirements' "$_DESC"
out="$(validate_manifest "$TEST_TEMP_DIR/c1-ok/manifest.yaml" 2>&1)"; rc=$?
assert_eq "[C1] the new form is accepted" "0" "$rc"
_card "$TEST_TEMP_DIR/c1-nofor" 'takes:
  - topic: ask
  - topic: change
    for: the code' "$_DESC"
out="$(validate_manifest "$TEST_TEMP_DIR/c1-nofor/manifest.yaml" 2>&1)"; rc=$?
assert_eq "[C1] a take with no for: is refused" "1" "$rc"
assert_contains "[C1] … naming its topic" "$out" "take 'ask' has no for:"
_card "$TEST_TEMP_DIR/c1-bad" 'takes:
  - topic: test-logs
    for: the logs' "$_DESC"
out="$(validate_manifest "$TEST_TEMP_DIR/c1-bad/manifest.yaml" 2>&1)"; rc=$?
assert_eq "[C1] an unknown topic is refused" "1" "$rc"
assert_contains "[C1] … naming it" "$out" "takes 'test-logs'"
_card "$TEST_TEMP_DIR/c1-old" 'takes: [ask, change]' "$_DESC"
out="$(validate_manifest "$TEST_TEMP_DIR/c1-old/manifest.yaml" 2>&1)"; rc=$?
assert_eq "[C1] the old one-line form is refused" "1" "$rc"
assert_contains "[C1] … showing the new one" "$out" "- topic: ask"

print_test_section "C2: an output with a topic has a description"
_card "$TEST_TEMP_DIR/c2-nodesc" "" '    topic: ask'
out="$(validate_manifest "$TEST_TEMP_DIR/c2-nodesc/manifest.yaml" 2>&1)"; rc=$?
assert_eq "[C2] an output with a topic and no description is refused" "1" "$rc"
assert_contains "[C2] … naming the output" "$out" "output 'v_result' has a topic but no description:"
_card "$TEST_TEMP_DIR/c2-notopic" "" ""
out="$(validate_manifest "$TEST_TEMP_DIR/c2-notopic/manifest.yaml" 2>&1)"; rc=$?
assert_eq "[C2] an output with no topic needs no description" "0" "$rc"

print_test_section "C3: Previous work reads the new form"
takes=""
_sp_takes_v takes "$TEST_TEMP_DIR/c1-ok/manifest.yaml"
assert_eq "[C3] the topics of the new form" " ask requirement-findings " "$takes"

print_test_section "C4: every taken output's findings, labelled by their output"
PROOT="$TEST_TEMP_DIR/plugins"; STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"
mkdir -p "$ART" "$PROOT/tool/tt-test"
cat > "$PROOT/tool/tt-test/manifest.yaml" <<'EOF'
id: tt-test
name: tt-test
kind: tool
version: 0.0.1
hooks:
  run: x_run
outputs:
  - id: tt_results
    path: ${artifact_dir}/tt-results.json
    type: json
    required: true
    primary: true
    topic: code-findings
    description: the suite's result
  - id: tt_check_result
    path: ${artifact_dir}/tt-check-result.json
    type: json
    required: false
    topic: requirement-findings
    description: the check's result
EOF
printf 'x_run() { return 0; }\n' > "$PROOT/tool/tt-test/plugin.sh"
init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1
stage_result_write "$ART/tt-results.json" fail fixture '{"findings":[{"n":1,"text":"SUITE-FINDING"}]}'
stage_result_write "$ART/tt-check-result.json" fail fixture '{"findings":[{"n":1,"text":"CHECK-FINDING"}]}'
_update_stage_status "$STATE/pipeline-state.json" tt-test complete
_zbuild_state_set_stage_verdict "$STATE/pipeline-state.json" tt-test fail
_consumer() {   # _consumer <name> <topic>...
    local s="$1" t; shift
    mkdir -p "$PROOT/agent/$s"
    {
        printf 'id: %s\nname: %s\nkind: agent\nversion: 0.0.1\ntakes:\n' "$s" "$s"
        for t in "$@"; do printf '  - topic: %s\n    for: x\n' "$t"; done
        printf 'hooks:\n  run: x_run\noutputs:\n  - id: %s_r\n    path: ${artifact_dir}/%s-r.json\n    type: json\n    required: true\n    primary: true\n' "${s//-/_}" "$s"
    } > "$PROOT/agent/$s/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$PROOT/agent/$s/plugin.sh"
}
_consumer tt-req requirement-findings
_consumer tt-code code-findings
_consumer tt-both requirement-findings code-findings
_TPL_STAGES=(tt-test tt-req tt-code tt-both)
_pw() { local idx; idx="$(_inputs_resolve_stage "$1" "$PROOT" "$STATE")"
        _stage_block_previous_work "$1" "$STATE" "$PROOT" "$idx" "$TEST_TEMP_DIR" "$PROOT/agent/$1/manifest.yaml"; }
pw_req="$(_pw tt-req)"; pw_code="$(_pw tt-code)"; pw_both="$(_pw tt-both)"
assert_contains "[C4] a non-primary output's finding reaches a stage that takes its topic" "$pw_req" \
    "tt-check finding 1 (opened by tt-test): CHECK-FINDING"
assert_not_contains "[C4] … and the primary output's (untaken) finding does not" "$pw_req" "SUITE-FINDING"
assert_contains "[C4] the primary output's finding keeps its label" "$pw_code" "tt-test finding 1 (opened by tt-test): SUITE-FINDING"
assert_not_contains "[C4] an untaken output's finding never reaches a stage" "$pw_code" "CHECK-FINDING"
assert_eq "[C4] a stage that takes both sees each finding once" "1|1" \
    "$(grep -c 'CHECK-FINDING' <<<"$pw_both")|$(grep -c 'SUITE-FINDING' <<<"$pw_both")"

print_test_section "C5: the shipped stages state their contract"
_card_gaps() {   # every take with no for:, every topic'd output with no description:
    awk -v m="$1" '
        function flush_out() { if (oid != "" && otopic && !odesc) print m ": output " oid " has no description" ; oid=""; otopic=0; odesc=0 }
        function flush_take() { if (tk != "" && !tfor) print m ": take " tk " has no for"; tk=""; tfor=0 }
        /^takes:/ { sec="takes"; next }
        /^outputs:/ { sec="outputs"; next }
        /^[a-zA-Z_]/ { flush_take(); flush_out(); sec=""; next }
        sec=="takes" && /^  - topic:/ { flush_take(); tk=$3; next }
        sec=="takes" && /^    for:/ { tfor=1; next }
        sec=="outputs" && /^  - id:/ { flush_out(); oid=$3; next }
        sec=="outputs" && /^    topic:/ { otopic=1; next }
        sec=="outputs" && /^    description:/ { odesc=1; next }
        END { flush_take(); flush_out() }' "$1"
}
gaps=""
for m in "$REPO_ROOT"/plugins/*/*/manifest.yaml; do gaps+="$(_card_gaps "${m#"$REPO_ROOT"/}")"; done
assert_eq "[C5] every shipped take has a for:, every shipped output with a topic a description:" "" "$gaps"
assert_eq "[C5] no shipped manifest keeps the one-line takes: form" "" \
    "$(grep -lE '^takes:[[:space:]]*\[' "$REPO_ROOT"/plugins/*/*/manifest.yaml 2>/dev/null || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
