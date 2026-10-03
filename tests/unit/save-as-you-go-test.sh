#!/usr/bin/env bash
# tests/unit/save-as-you-go-test.sh — every stage that calls a model saves its
# work as it goes, and a stage cut off by time or turns hands over what it found
# (#2270).
#
# Why: #1844 run 37066147994's correctness lens read the plugin, traced every
# path, had found real defects — and was killed at 300 s with nothing written:
# the review recorded "did not run". Only plan declared the engine's save-as-you-
# go file (`role: checkpoint`, scripts/lib/stage-checkpoint.sh). Eric
# (2026-10-03): every stage gets it.
#
# C1 [change] every plugin that calls the model declares a `role: checkpoint` output
# C2 [change] map elements running in parallel never share a checkpoint file:
#             `${map_element}` in a path resolves to each element's own name
# C3 [change] a stage that ends cut off (timed_out / out_of_turns) with notes in
#             its checkpoint hands them on: the summary later stages read
#             carries them, marked as unfinished work
# C4 [guard]  a stage that finished does not get its checkpoint appended
# C5 [change] with no map element set, `${map_element}` stays unresolved — it
#             never collapses to "" and points at a file no element owns
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every stage saves as it goes, and hands over what it found (#2270)"
setup_test_env "save-as-you-go"

print_test_section "C1: every model-calling plugin declares a checkpoint"
_missing=""
for d in "$REPO_ROOT"/plugins/*/*/; do
    _calls=0
    for f in "$d"*.sh "$d"lib/*.sh; do
        [[ -f "$f" ]] || continue
        grep -qE 'route_to_model(_loop)?[[:space:]]' "$f" && { _calls=1; break; }
    done
    [[ $_calls -eq 1 ]] || continue
    grep -qE '^[[:space:]]+role:[[:space:]]*checkpoint' "$d/manifest.yaml" 2>/dev/null \
        || _missing+="${d#"$REPO_ROOT"/}"$'\n'
done
assert_eq "[C1] every plugin that calls the model declares a checkpoint" "" "$_missing"

print_test_section "C2: each map element has its own checkpoint"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh" >/dev/null 2>&1 || true
# shellcheck disable=SC2016  # a literal template path
_a="$(ZBUILD_MAP_ELEMENT=correctness _verdict_resolve_path '${artifact_dir}/lens-${map_element}-checkpoint.md' /s)"
# shellcheck disable=SC2016
_b="$(ZBUILD_MAP_ELEMENT=red-team _verdict_resolve_path '${artifact_dir}/lens-${map_element}-checkpoint.md' /s)"
assert_eq "[C2] the correctness element's checkpoint path" "/s/artifacts/lens-correctness-checkpoint.md" "$_a"
assert_eq "[C2] the red-team element's checkpoint path" "/s/artifacts/lens-red-team-checkpoint.md" "$_b"
# shellcheck disable=SC2016
_c="$(ZBUILD_MAP_ELEMENT='../x' _verdict_resolve_path '${artifact_dir}/lens-${map_element}.md' /s)"
assert_eq "[C2] an element name cannot leave the artifacts folder" "/s/artifacts/lens-___x.md" "$_c"

# shellcheck disable=SC2016  # a literal template path
_d="$(unset ZBUILD_MAP_ELEMENT; _verdict_resolve_path '${artifact_dir}/lens-${map_element}-checkpoint.md' /s)"
if [[ "$_d" == "/s/artifacts/lens--checkpoint.md" ]]; then
    assert_fail "[C5] no element: the path does not collapse to lens--checkpoint.md" "it did"
else
    assert_pass "[C5] no element: the path does not collapse to lens--checkpoint.md"
fi

print_test_section "C3/C4: a cut-off stage hands over its notes"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh" >/dev/null 2>&1 || true
_handover() {   # _handover <disposition> → the summary block a later stage reads
    local s="$TEST_TEMP_DIR/state-$1" p="$TEST_TEMP_DIR/plugins-$1"
    mkdir -p "$s/artifacts" "$p/agent/cut"
    cat > "$p/agent/cut/manifest.yaml" <<'MF'
id: cut
kind: agent
provides:
  role: cut
  result_contract: 2
outputs:
  - id: cut-result
    path: ${artifact_dir}/cut-result.json
    format: json
    required: true
    primary: true
  - id: cut-checkpoint
    path: ${artifact_dir}/cut-checkpoint.md
    format: markdown
    required: false
    role: checkpoint
  - id: cut-summary
    path: ${artifact_dir}/cut-summary.md
    format: markdown
    required: false
    summary: true
MF
    jq -n --arg d "$1" '{result_contract:2,verdict:"error",disposition:$d,reason:"stopped"}' > "$s/artifacts/cut-result.json"
    printf '## cut — error\n\n- the call stopped\n' > "$s/artifacts/cut-summary.md"
    printf 'Read plugin.sh: the dry run writes no result.\nNext: check the merge path.\n' > "$s/artifacts/cut-checkpoint.md"
    printf '{"stage_statuses":{"cut":"failed"},"stage_verdicts":{"cut":"error"}}\n' > "$s/pipeline-state.json"
    ( _TPL_STAGES=(cut); export ZBUILD_CURRENT_STAGE=later
      stage_summaries_prompt_block "$s/pipeline-state.json" "$p" 2>/dev/null )
}
_cut="$(_handover timed_out)"
assert_contains "[C3] the notes reach the stages that follow" "$_cut" "the dry run writes no result"
assert_contains "[C3] they are marked as unfinished work" "$_cut" "before it was cut off"
_done="$(_handover complete)"
if grep -qF "the dry run writes no result" <<< "$_done"; then
    assert_fail "[C4] a finished stage's checkpoint is not appended" "it was"
else
    assert_pass "[C4] a finished stage's checkpoint is not appended"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
