#!/usr/bin/env bash
# tests/unit/own-check-retry-test.sh — when a stage's own check fails, the
# engine runs it again and the next try is told what the check found (#2460,
# ADR-054 §6a).
#
# Why: test-author and build each re-asked their own model inside one try
# (config.check_rounds), then reported `fail`, which the engine never retries —
# so build ran on tests test-author already knew were wrong (#1805 run
# 41546214211). design already ends such a try `unusable` with its findings and
# the engine reruns it. Every stage now works that way.
#
# R1 [guard]  test-author's next try is shown, under Previous work, the
#             findings its own check left in its result
# R2 [guard]  build's next try is shown the finding it left when it said done,
#             changed nothing, and its test still failed
# R3 [guard]  the engine runs again a try that ended `unusable` with new
#             findings about its own work, even when it changed no file
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
source "$REPO_ROOT/core/state/resume.sh"
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
source "$REPO_ROOT/scripts/lib/stage-result.sh"
print_test_header "a stage whose own check fails is run again, told what it found (#2460)"
setup_test_env "own-check-retry"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true

PROOT="$REPO_ROOT/plugins"; STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"
mkdir -p "$ART"
init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1
export ZBUILD_ARTIFACT_DIR="$ART" ZBUILD_STATE_DIR="$STATE"
_TPL_STAGES=(test-author build)

# ── R1 ───────────────────────────────────────────────────────────────────────
stage_result_write "$ART/test-author-result.json" unusable "1 finding open" \
    '{"findings":[{"n":1,"text":"SPEC-4: tests/x-test.sh passes on the code from before this change"}]}'
_update_stage_status "$STATE/pipeline-state.json" test-author complete
_idx="$(_inputs_resolve_stage test-author "$PROOT" "$STATE")"
_pw="$(_stage_block_previous_work test-author "$STATE" "$PROOT" "$_idx" "" "$PROOT/agent/test-author/manifest.yaml")"
assert_contains "[R1] test-author's next try is shown its own check's finding" "$_pw" "passes on the code from before this change"

# ── R2 ───────────────────────────────────────────────────────────────────────
jq -n '{schema_version:4, files_changed:[], data:{build_kind:"inert_build",
        findings:[{n:1, text:"you said the work was done but changed no file, and tests/x-test.sh still fails"}]}}' \
    > "$ART/build-summary.json"
stage_result_add "$ART/build-summary.json" unusable false_completion_detected >/dev/null 2>&1
_update_stage_status "$STATE/pipeline-state.json" build complete
_idx="$(_inputs_resolve_stage build "$PROOT" "$STATE")"
_pw="$(_stage_block_previous_work build "$STATE" "$PROOT" "$_idx" "" "$PROOT/agent/build/manifest.yaml")"
assert_contains "[R2] build's next try is shown that its test still fails" "$_pw" "tests/x-test.sh still fails"

# ── R3 ───────────────────────────────────────────────────────────────────────
source "$REPO_ROOT/core/plugin-registry/attempt-archive.sh"
source "$REPO_ROOT/scripts/lib/stage-retry.sh"
_disp() { printf -v "$1" '%s' unusable; }
runner_read_stage_disposition_v() { printf -v "$1" '%s' unusable; }
_ATTEMPT_LAST_PROGRESS=true
if stage_retry_next "$PROOT/agent/build" build "$STATE/pipeline-state.json" 1 1 2 >/dev/null 2>&1; then
    assert_pass "[R3] an unusable try with new findings (progress) is run again"
else
    assert_fail "[R3] an unusable try with new findings (progress) is run again" "no retry"
fi
_ATTEMPT_LAST_PROGRESS=false
if stage_retry_next "$PROOT/agent/build" build "$STATE/pipeline-state.json" 1 1 2 >/dev/null 2>&1; then
    assert_fail "[R3] ...the same findings again (no progress) are not" "retried"
else
    assert_pass "[R3] ...the same findings again (no progress) are not"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
