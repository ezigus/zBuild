#!/usr/bin/env bash
# tests/unit/shape-floor-content-stable-test.sh — a shape change whose floor files
# are still correct passes without editing them (#1874).
#
# Why: shape-floor required every floor file (event goldens, stage-order tests)
# to carry a real edit whenever a shape-change path was touched. A change that
# touches cycle-orchestrator.sh WITHOUT changing the pipeline's shape leaves
# those files correct as they are — and since #2183 refuses comment-only
# touches, it could never pass (#2032, run 36969130031, every iteration).
#
# The evidence that a file is still correct is this run's own full test pass on
# this exact code: shape-floor reads the test stage's result (by name), and
#   - an unedited floor TEST file is verified when the pass did not list it as
#     failing;
#   - an unedited GOLDEN is verified only when nothing failed (a golden
#     mismatch shows up as some other test failing).
#
# C1 [change] full pass on this tree, nothing failed → pass, floor unedited
# C2 [guard]  the stage-order test is among the failures → still fail
# C3 [guard]  the pass was on a different tree → fail
# C4 [guard]  a targeted (partial) run → fail
# C5 [guard]  no test result at all → fail, as before
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "shape-floor: a still-correct floor needs no edit (#1874)"
setup_test_env "shape-floor-content-stable"
# shellcheck source=../../plugins/tool/shape-floor/plugin.sh
source "$REPO_ROOT/plugins/tool/shape-floor/plugin.sh"

T="$TEST_TEMP_DIR/target"
mkdir -p "$T/config" "$T/tests/golden/full" "$T/tests/unit" "$T/core/pipeline"
printf 'core/pipeline/runner.sh\n' > "$T/config/shape-change-paths.txt"
printf 'pipeline.start\n' > "$T/tests/golden/full/event-sequence.golden"
# shellcheck disable=SC2016  # literal source text
printf 'assert_eq "x" "impact" "${_TPL_STAGES[2]}"\n' > "$T/tests/unit/order-test.sh"
printf 'echo runner\n' > "$T/core/pipeline/runner.sh"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t \
  && git add -A && git commit -qm base ) >/dev/null 2>&1
TREE="$(git -C "$T" rev-parse 'HEAD^{tree}')"
export ZBUILD_REPO_ROOT="$T" ZBUILD_DIFF_CMD="printf 'core/pipeline/runner.sh\n'"
S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"; printf '{}\n' > "$S/pipeline-state.json"
export ZBUILD_ARTIFACT_DIR="$S/artifacts"

# _results <tree> <run_mode> <failures-json> — the test stage's result.
_results() {
    jq -n --arg t "$1" --arg m "$2" --argjson f "$3" \
        '{result_contract:2, verdict:(if ($f|length)==0 then "pass" else "fail" end),
          disposition:"complete", reason:"r", run_mode:$m,
          data:{tree_sha:$t, run_mode:$m, failed:($f|length), failures:$f}}' > "$S/artifacts/test-results.json"
    jq -n --arg p "$S/artifacts/test-results.json" '{inputs:{test_results:$p}}' > "$S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$S/stage-inputs.json"
}
_verdict() {
    shape_floor_run shape-floor "$S/pipeline-state.json" >/dev/null 2>&1
    jq -r '.verdict // empty' "$S/artifacts/shape-floor-result.json" 2>/dev/null
}

_results "$TREE" full '[]'
assert_eq "[C1] full pass on this tree, nothing failed → pass" "pass" "$(_verdict)"
_results "$TREE" full '[{"file":"tests/unit/order-test.sh","reason":"x"}]'
assert_eq "[C2] the order test failed → fail" "fail" "$(_verdict)"
_results "0000000000000000000000000000000000000000" full '[]'
assert_eq "[C3] a pass on another tree → fail" "fail" "$(_verdict)"
_results "$TREE" targeted '[]'
assert_eq "[C4] a targeted run → fail" "fail" "$(_verdict)"
rm -f "$S/artifacts/test-results.json"; unset ZBUILD_STAGE_INPUTS
assert_eq "[C5] no test result → fail" "fail" "$(_verdict)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
