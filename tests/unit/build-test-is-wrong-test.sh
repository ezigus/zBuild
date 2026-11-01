#!/usr/bin/env bash
# tests/unit/build-test-is-wrong-test.sh — build can say a test is wrong, and
# that reaches test-author without build's code (ADR-068 §6, ADR-071 §1,
# amended 2026-10-31, #2441).
#
# Why: #1754's SPEC-4 test could never pass (its fake skipped every path holding
# "intake-result", and the test's own folder was named plugin-intake-result.*).
# Build saw it fail on code that did what the requirement said, may not edit a
# test, and had no way to say so: it spent 12 model calls debugging it. Its
# answers were all `change`, which test-author does not take (#2022), so even an
# answer would not have reached the stage that owns the test.
#
# W1 [change] build's prompt says how to answer a test that is wrong, and to
#             stop working on it
# W2 [change] build declares build-tests-result.json on topic code-findings,
#             with a description
# W3 [change] test-author's Previous work shows build's "test is wrong"
#             findings, and nothing of build's code: not its diff, not its
#             summary
# W4 [change] build gives that answer as soon as it is sure, not after more
#             work on the test (#2443: #1754 build ran out of time first)
# W5 [change] build writes its notes first, and each finding before its next
#             step (#2443)
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
# shellcheck source=../../plugins/agent/build/lib/prompt.sh
source "$REPO_ROOT/plugins/agent/build/lib/prompt.sh"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then
        assert_fail "$1" "output unexpectedly has: $3"
    else
        assert_pass "$1"
    fi
}

print_test_header "build can say a test is wrong; test-author hears it, blind to the code (#2441)"
setup_test_env "build-test-is-wrong"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true

# ── W1 ───────────────────────────────────────────────────────────────────────
_instr="$(_build_compose_instructions "x.sh")"
assert_contains "[W1] build is told how to answer a test that is wrong" "$_instr" \
    "nothing to do — the test is wrong:"
assert_contains "[W1] ...naming the test file and why" "$_instr" "<test file>: <why>"
assert_contains "[W1] ...and to stop working on it" "$_instr" "stop working on that test"
assert_contains "[W4] build answers as soon as it is sure" "$_instr" "as soon as you are sure"
assert_contains "[W5] build writes its notes first" "$_instr" "Write your notes file first"
assert_contains "[W5] ...and each finding before its next step" "$_instr" "before your next step"

# ── W2 ───────────────────────────────────────────────────────────────────────
BM="$REPO_ROOT/plugins/agent/build/manifest.yaml"
_entry="$(awk '/^  - id: build_tests$/ {f=1} f && /^  - id: / && !/build_tests/ {exit} f' "$BM")"
assert_contains "[W2] build declares build_tests" "$_entry" "build-tests-result.json"
assert_contains "[W2] ...on topic code-findings" "$_entry" "topic: code-findings"
assert_contains "[W2] ...described" "$_entry" "description:"

# ── W3 ───────────────────────────────────────────────────────────────────────
PROOT="$REPO_ROOT/plugins"
STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; mkdir -p "$ART"
init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1
printf 'diff --git a/x b/x\n+BUILD-SECRET-DIFF\n' > "$ART/diff.patch"
stage_result_write "$ART/build-summary.json" pass "BUILD-SECRET-SUMMARY-JSON"
printf '## build — pass\nBUILD-SECRET-SUMMARY-MD\n' > "$ART/build-summary.md"
stage_result_write "$ART/build-tests-result.json" fail "build says 1 test is wrong" \
    '{"findings":[{"n":1,"text":"test finding 1: tests/x-test.sh: TEST-IS-WRONG-BECAUSE"}]}'
_update_stage_status "$STATE/pipeline-state.json" build complete
_zbuild_state_set_stage_verdict "$STATE/pipeline-state.json" build pass
_TPL_STAGES=(build test-author)
TGT="$TEST_TEMP_DIR/target"; git init -q -b main "$TGT"
TAM="$PROOT/agent/test-author/manifest.yaml"
idx="$(_inputs_resolve_stage test-author "$PROOT" "$STATE")"
pw="$(_stage_block_previous_work test-author "$STATE" "$PROOT" "$idx" "$TGT" "$TAM")"
assert_contains "[W3] test-author is shown build's 'test is wrong' finding" "$pw" "TEST-IS-WRONG-BECAUSE"
assert_contains "[W3] ...labelled so it can answer it" "$pw" "build-tests finding 1"
assert_not_contains "[W3] ...and not build's diff" "$pw" "BUILD-SECRET-DIFF"
assert_not_contains "[W3] ...nor build's summary" "$pw" "BUILD-SECRET-SUMMARY-MD"
assert_not_contains "[W3] ...nor build's result" "$pw" "BUILD-SECRET-SUMMARY-JSON"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
