#!/usr/bin/env bash
# plugins/agent/build/tests/build-test-is-wrong-run-test.sh — build's answer
# that a test is wrong becomes a finding in build-tests-result.json (ADR-068 §6,
# ADR-071 §1, amended 2026-10-31, #2441). Its own file: build-test.sh is past
# the 500-line mark (review on #2442).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "build: a 'test is wrong' answer reaches build-tests-result.json (#2441)"
setup_test_env "plugin-build-test-is-wrong"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_RUN_ID="build-test-wrong-$$" ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
ZBUILD_ISSUE="$(zb_test_issue)"; export ZBUILD_ISSUE

# shellcheck source=../../../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

SCOPE_MANIFEST="$TEST_TEMP_DIR/scope-manifest.md"
printf '+ tests/\n+ plugins/\n' > "$SCOPE_MANIFEST"
setup_build_repo() {
    local repo="$TEST_TEMP_DIR/$1"
    mkdir -p "$repo/tests/fixtures"
    ( cd "$repo" && git init -q && git config user.email t@zbuild && git config user.name t \
      && echo seed > tests/fixtures/seed.txt && git add -A && git commit -q -m seed )
    printf '%s\n' "$repo"
}
apply_scope_redaction() { cp "$1" "$2"; emit_event "redaction.applied" "input=$1" "output=$2" \
    "size_before=0" "size_after=0" "redactions=0" "scope_hash=mock" "cycle=0"; }
# The model's reply is MOCK_LOOP_RESPONSE; the call ends on the done sentinel.
MOCK_LOOP_RESPONSE=""
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=1; _ROUTE_LOOP_OUTPUT_TOKENS=1
    _ROUTE_LOOP_LAST_RESPONSE="$MOCK_LOOP_RESPONSE"
    return 0
}
PLAN_JSON_PROMPT="$TEST_TEMP_DIR/plan.json"
printf '%s' '{"schema_version":1,"goal":"g","steps":[{"id":"s1","description":"d","files":["tests/fixtures/x.txt"],"estimated_lines":1}]}' > "$PLAN_JSON_PROMPT"

# ─── [#2441] build says a test is wrong → build-tests-result.json ────────────
# ADR-068 §6 / ADR-071 §1 (amended 2026-10-31): build's answer that a test is
# wrong is a finding for the stage that owns the test, in its own output on
# topic code-findings; nothing else of build's is in it.
print_test_section "[#2441] a 'test is wrong' answer becomes a finding in build-tests-result.json"
ARTIFACT_DIR_TW="$TEST_TEMP_DIR/artifacts_testwrong"
mkdir -p "$ARTIFACT_DIR_TW"
cp "$PLAN_JSON_PROMPT" "$ARTIFACT_DIR_TW/plan.json"
REPO_TW="$(setup_build_repo "repo_testwrong")"
export ZBUILD_REPO_ROOT="$REPO_TW"
MOCK_LOOP_RESPONSE=$'Checked it.\nANSWER test finding 2: nothing to do — the test is wrong: plugins/agent/intake/tests/intake-result-test.sh: its fake skips every path holding intake-result, and the test runs in plugin-intake-result.*\nLOOP_COMPLETE'
set +e
_build_stage_run_inner "$SCOPE_MANIFEST" "$ARTIFACT_DIR_TW/plan.json" "$ARTIFACT_DIR_TW/diff.patch" \
    "$ARTIFACT_DIR_TW/build-summary.json" "$ARTIFACT_DIR_TW" >/dev/null 2>&1
set -e
_tw="$ARTIFACT_DIR_TW/build-tests-result.json"
assert_file_exists "[#2441] build-tests-result.json written" "$_tw"
assert_eq "[#2441] it holds the one finding" "1" "$(jq -r '.data.findings | length' "$_tw" 2>/dev/null)"
assert_contains "[#2441] the finding names the test file" "$(jq -r '.data.findings[0].text' "$_tw" 2>/dev/null)" \
    "plugins/agent/intake/tests/intake-result-test.sh"
assert_contains "[#2441] ...says why" "$(jq -r '.data.findings[0].text' "$_tw" 2>/dev/null)" \
    "its fake skips every path holding intake-result"
assert_contains "[#2441] ...and which finding build answered" "$(jq -r '.data.findings[0].text' "$_tw" 2>/dev/null)" \
    "test finding 2"
assert_eq "[#2441] outcome fail: a test must be fixed" "fail" "$(jq -r '.outcome' "$_tw" 2>/dev/null)"
if grep -q 'diff --git\|build-test-dummy' "$_tw" 2>/dev/null; then
    assert_fail "[#2441] nothing of build's change is in it" "$(cat "$_tw")"
else
    assert_pass "[#2441] nothing of build's change is in it"
fi
MOCK_LOOP_RESPONSE=$'All done.\nLOOP_COMPLETE'
set +e
_build_stage_run_inner "$SCOPE_MANIFEST" "$ARTIFACT_DIR_TW/plan.json" "$ARTIFACT_DIR_TW/diff.patch" \
    "$ARTIFACT_DIR_TW/build-summary.json" "$ARTIFACT_DIR_TW" >/dev/null 2>&1
set -e
assert_file_not_exists "[#2441] a try with no such answer leaves no file from the last try" "$_tw"
MOCK_LOOP_RESPONSE=""

cleanup_test_env
print_test_results
exit $((FAIL > 0))
