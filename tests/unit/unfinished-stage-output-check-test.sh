#!/usr/bin/env bash
# tests/unit/unfinished-stage-output-check-test.sh — a stage that says it did not
# finish is not failed for the outputs it could not write (#2252 D2).
#
# Why: #1844 run 36969128968 — design's model call timed out with no design. The
# plugin did the right thing: returned 0 and wrote `disposition: timed_out` (the
# engine's word for "retry me"). Then the required-output check found design.md
# missing, turned the dispatch into rc=1, and wrote the artifact-contract marker
# — so the run read `broken` ("no reason given") and halted instead of retrying.
#
# U1 [change] declared timed_out + a required output missing → the dispatch
#             succeeds and no contract-violation marker is written
# U2 [change] ...and the skip is announced, naming the disposition
# U3 [guard]  declared complete + a required output missing → still a violation
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/disposition.sh
source "$REPO_ROOT/core/pipeline/disposition.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

print_test_header "an unfinished stage is not failed for missing outputs (#2252 D2)"
setup_test_env "unfinished-stage-output-check"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
SF="$S/pipeline-state.json"; printf '{}\n' > "$SF"
export ZBUILD_STATE_DIR="$S" ZBUILD_ARTIFACT_DIR="$S/artifacts"
# _plugin <name> <disposition> — writes its result, never its work output.
_plugin() {
    local d="$TEST_TEMP_DIR/plugins/agent/$1"; mkdir -p "$d"
    cat > "$d/manifest.yaml" <<EOF
id: $1
kind: agent
version: 0.0.1
hooks:
  run: ${1//-/_}_run
requires:
  core:
    - redaction
provides:
  result_contract: 2
config:
  valid_verdicts: [complete, incomplete]
outputs:
  - id: result
    path: "\${artifact_dir}/$1-result.json"
    required: true
    primary: true
  - id: work
    path: "\${artifact_dir}/$1-work.md"
    required: true
EOF
    cat > "$d/plugin.sh" <<EOF
${1//-/_}_run() {
    printf '{"result_contract":2,"verdict":"incomplete","disposition":"$2","reason":"r"}\n' \\
        > "\$ZBUILD_ARTIFACT_DIR/$1-result.json"
    return 0
}
EOF
    printf '%s' "$d"
}

P1="$(_plugin late-stage timed_out)"
export ZBUILD_CURRENT_STAGE=late-stage
plugin_hook_call "$P1" run late-stage "$SF" >/dev/null 2>&1; rc=$?
assert_eq "[U1] a timed_out stage missing a required output → dispatch rc 0" "0" "$rc"
assert_eq "[U1] ...and no contract-violation marker" "absent" \
    "$([[ -e "$S/runtime/artifact-contract-violated" ]] && echo present || echo absent)"
assert_contains "[U2] the skip is announced with the disposition" \
    "$(grep 'artifact_check_skipped' "$ZBUILD_EVENTS_JSONL" 2>/dev/null)" "timed_out"

rm -f "$S/runtime/artifact-contract-violated"
P3="$(_plugin done-stage complete)"
export ZBUILD_CURRENT_STAGE=done-stage
plugin_hook_call "$P3" run done-stage "$SF" >/dev/null 2>&1; rc=$?
assert_eq "[U3] a complete stage missing a required output → still rc 1" "1" "$rc"
assert_eq "[U3] ...with the marker" "present" \
    "$([[ -e "$S/runtime/artifact-contract-violated" ]] && echo present || echo absent)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
