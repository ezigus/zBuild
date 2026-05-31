#!/usr/bin/env bash
# Tests: plugins/agent/test_assessment plugin (#567)
#
# Pattern 1 LLM-interprets-test-results stage. Mocks route_to_model + redaction;
# asserts schema, verdict invariant, dual-path artifact write, env save/restore,
# event emission.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: test_assessment (#567)"
setup_test_env "plugin-test-assessment"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/test_assessment"

# ─── Fixture state dir ────────────────────────────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"test","issue":"567","stage_statuses":{}}' > "$STATE_FILE"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE

# Seed input artifacts the stage reads.
cat > "$ARTIFACTS_DIR/test-results.json" <<'TR'
{"schema_version":1,"verdict":"fail","exit_code":1,"passed":5,"failed":3,"test_output":"FAIL AuthTest: expected 200 got 401","diff_applied":true,"test_cmd":"npm test"}
TR
cat > "$ARTIFACTS_DIR/plan.json" <<'PJ'
{"schema_version":1,"title":"add auth","goal":"add login","steps":[{"id":"step-1","description":"add login","files":["src/auth.js"],"estimated_lines":20}],"estimated_total_lines":20,"notes":""}
PJ
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"complete"}
BS

# ─── Source plugin under test ─────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/test_assessment/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Mocks ───────────────────────────────────────────────────────────────────
_REDACT_CALLED_FILE="$TEST_TEMP_DIR/redact-called"
apply_scope_redaction() {
    local _input="$1" _output="$2"
    printf '%s' "$3,$5" > "$_REDACT_CALLED_FILE"
    cat "$_input" > "$_output"
    return 0
}

_CAPTURED_PROMPT="$TEST_TEMP_DIR/captured-prompt.txt"
_CAPTURED_ENV_JSON="$TEST_TEMP_DIR/captured-env-json.txt"
_CAPTURED_ARTIFACT_ID="$TEST_TEMP_DIR/captured-artifact-id.txt"
_CAPTURED_TIER="$TEST_TEMP_DIR/captured-tier.txt"
: > "$_CAPTURED_PROMPT"
: > "$_CAPTURED_ENV_JSON"
: > "$_CAPTURED_ARTIFACT_ID"
: > "$_CAPTURED_TIER"

# CANNED_RESPONSE drives the mock; tests reassign it between cases.
CANNED_RESPONSE='{"schema_version":1,"verdict":"fail","summary":"3 failing","diagnosis":"401 expected 200","required_changes":["fix auth header"],"agrees_with_build_complete":false,"branch_numstat":"files=1 add=10 del=2","failure_summary_md":"## Failures\n- AuthTest","iter":1}'

route_to_model() {
    printf '%s' "${1:-}" > "$_CAPTURED_TIER"
    printf '%s' "${2:-}" > "$_CAPTURED_PROMPT"
    printf '%s' "${ZBUILD_ROUTER_JSON_OUTPUT:-unset}" > "$_CAPTURED_ENV_JSON"
    printf '%s' "${ZBUILD_ROUTER_ARTIFACT_ID:-unset}" > "$_CAPTURED_ARTIFACT_ID"
    printf '%s\n' "$CANNED_RESPONSE"
    return 0
}

# ─── Test 1: init ────────────────────────────────────────────────────────────
test_assessment_init >/dev/null 2>&1 || true
assert_eq "T1 init sets ZBUILD_PLUGIN" "test_assessment" "${ZBUILD_PLUGIN:-}"
assert_eq "T1 init sets ZBUILD_PLUGIN_KIND" "agent" "${ZBUILD_PLUGIN_KIND:-}"

# ─── Test 2: happy path — fail verdict (LLM disagrees with build pass) ───────
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T2 run returns rc=0" "0" "$rc"
assert_file_exists "T2 test-assessment.json created (flat path)" "$ARTIFACTS_DIR/test-assessment.json"
assert_file_exists "T2 test-assessment.md created (flat path)" "$ARTIFACTS_DIR/test-assessment.md"

# ─── Test 3: schema is valid ─────────────────────────────────────────────────
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
sv="$(printf '%s' "$content" | jq -r '.schema_version' 2>/dev/null)"
assert_eq "T3 schema_version=1" "1" "$sv"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T3 verdict=fail" "fail" "$v"
assert_contains "T3 failure_summary_md present" "$content" "AuthTest"

# ─── Test 4: tier T2 + envelope flags ─────────────────────────────────────────
assert_eq "T4 tier sent = T2" "T2" "$(cat "$_CAPTURED_TIER")"
assert_eq "T4 ZBUILD_ROUTER_JSON_OUTPUT=1 around router" "1" "$(cat "$_CAPTURED_ENV_JSON")"
assert_eq "T4 ZBUILD_ROUTER_ARTIFACT_ID=test_assessment" \
    "test_assessment" "$(cat "$_CAPTURED_ARTIFACT_ID")"

# ─── Test 5: env restored after route_to_model ───────────────────────────────
if [[ -z "${ZBUILD_ROUTER_JSON_OUTPUT:-}" ]]; then
    assert_pass "T5 ZBUILD_ROUTER_JSON_OUTPUT unset after run"
else
    assert_fail "T5 ZBUILD_ROUTER_JSON_OUTPUT unset after run" "still set: $ZBUILD_ROUTER_JSON_OUTPUT"
fi

# ─── Test 6: redaction was called ────────────────────────────────────────────
if [[ -s "$_REDACT_CALLED_FILE" ]]; then
    assert_pass "T6 apply_scope_redaction invoked"
else
    assert_fail "T6 apply_scope_redaction invoked" "no record"
fi

# ─── Test 7: prompt mentions key sections ────────────────────────────────────
prompt="$(cat "$_CAPTURED_PROMPT")"
assert_contains "T7 prompt mentions verdict enum" "$prompt" "verdict"
assert_contains "T7 prompt mentions agrees_with_build_complete" "$prompt" "agrees_with_build_complete"
assert_contains "T7 prompt mentions failure_summary_md" "$prompt" "failure_summary_md"
assert_contains "T7 prompt declares SINGLE JSON object" "$prompt" "SINGLE JSON"
assert_contains "T7 prompt embeds test_output" "$prompt" "AuthTest"
assert_contains "T7 prompt embeds build verdict" "$prompt" "complete"

# ─── Test 8: invariant downgrade — LLM says pass but test.failed > 0 ─────────
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
CANNED_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"looks ok","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","failure_summary_md":"All good.","iter":1}'
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T8 downgrade run returns rc=0" "0" "$rc"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
v="$(printf '%s' "$content" | jq -r '.verdict' 2>/dev/null)"
assert_eq "T8 verdict downgraded to inconclusive" "inconclusive" "$v"
note_present="$(printf '%s' "$content" | jq -r '.required_changes | map(select(. | test("downgrade"))) | length' 2>/dev/null)"
if [[ "$note_present" -ge 1 ]] 2>/dev/null; then
    assert_pass "T8 downgrade note added to required_changes"
else
    assert_fail "T8 downgrade note added to required_changes" "no note"
fi

# ─── Test 9: cycle-iter writes BOTH paths ────────────────────────────────────
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
export ZBUILD_CYCLE_ID="bt"
export ZBUILD_CYCLE_ITER="2"
CANNED_RESPONSE='{"schema_version":1,"verdict":"fail","summary":"x","diagnosis":"","required_changes":[],"agrees_with_build_complete":false,"branch_numstat":"unknown","failure_summary_md":"X.","iter":2}'
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T9 cycle-iter run rc=0" "0" "$rc"
assert_file_exists "T9 flat path written" "$ARTIFACTS_DIR/test-assessment.json"
assert_file_exists "T9 iter-scoped json written" "$STATE_DIR/cycle-bt/iter-2/test-assessment.json"
assert_file_exists "T9 iter-scoped md written" "$STATE_DIR/cycle-bt/iter-2/test-assessment.md"
unset ZBUILD_CYCLE_ID ZBUILD_CYCLE_ITER

# ─── Test 10: empty router response → error event, no artifact ───────────────
rm -f "$ARTIFACTS_DIR/test-assessment.json" "$ARTIFACTS_DIR/test-assessment.md"
CANNED_RESPONSE=""
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    assert_pass "T10 empty response → rc!=0"
else
    assert_fail "T10 empty response → rc!=0" "rc=0 unexpected"
fi
assert_file_not_exists "T10 no artifact on empty response" "$ARTIFACTS_DIR/test-assessment.json"

# ─── Test 11: malformed JSON response → error event, no artifact ────────────
CANNED_RESPONSE="this is not json at all"
set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    assert_pass "T11 malformed response → rc!=0"
else
    assert_fail "T11 malformed response → rc!=0" "rc=0 unexpected"
fi
assert_file_not_exists "T11 no artifact on malformed response" "$ARTIFACTS_DIR/test-assessment.json"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
