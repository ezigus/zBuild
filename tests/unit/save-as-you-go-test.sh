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
# C1 [change] every stage's notes file and budget are the engine's (ADR-067 §8);
#             no stage declares whether it calls a model
# C2 [change] map elements running in parallel never share a checkpoint file:
#             `${map_element}` in a path resolves to each element's own name
# C3 [change] a stage's notes come back to the stage itself in full; a later
#             stage's Previous work does not list them (another stage's notes
#             are its working file, not its output — ADR-067 §8)
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

print_test_section "C1: the engine needs no declaration from a stage"
# Every stage gets a notes file and the same per-call budget from the engine
# (ADR-067 §8); no stage says whether or how it calls a model.
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
assert_eq "[C1] no manifest declares model_calls" "" \
    "$(grep -l 'model_calls:' "$REPO_ROOT"/plugins/*/*/manifest.yaml 2>/dev/null || true)"

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

print_test_section "C3: a stage's notes come back to it, and only to it"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh" >/dev/null 2>&1 || true
_s3="$TEST_TEMP_DIR/state-cut"; _p3="$TEST_TEMP_DIR/plugins-cut"
mkdir -p "$_s3/artifacts" "$_p3/agent/cut"
cat > "$_p3/agent/cut/manifest.yaml" <<'MF'
id: cut
kind: agent
outputs:
  - id: cut-result
    path: ${artifact_dir}/cut-result.json
    format: json
    required: true
    primary: true
MF
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
stage_result_write "$_s3/artifacts/cut-result.json" timed_out stopped >/dev/null
_n3="$(stage_notes_path "$_s3" cut)"; mkdir -p "${_n3%/*}"
printf 'Read plugin.sh: the dry run writes no result.\n' > "$_n3"
printf '{"stage_statuses":{"cut":"failed"},"stage_verdicts":{"cut":"error"}}\n' > "$_s3/pipeline-state.json"
_cut="$( _TPL_STAGES=(cut); zb_test_previous_work "$_s3/pipeline-state.json" "$_p3" later )"
if grep -qF -- "$_n3" <<< "$_cut" || grep -qF "the dry run writes no result" <<< "$_cut"; then
    assert_fail "[C3] a later stage does not get another stage's notes" "notes path or text found"
else
    assert_pass "[C3] a later stage does not get another stage's notes"
fi
_own="$( _TPL_STAGES=(cut); zb_test_previous_work "$_s3/pipeline-state.json" "$_p3" cut )"
assert_contains "[C3] the stage itself gets its notes back, in full" "$_own" "the dry run writes no result"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
