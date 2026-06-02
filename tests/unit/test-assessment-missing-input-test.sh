#!/usr/bin/env bash
# Tests: plugins/agent/test_assessment fail-CLOSED on missing/malformed input (#627)
#
# Pre-#627: when test-results.json was missing or malformed, the plugin substituted
# '{}' and called the LLM with empty context — producing fabricated assessments.
# Post-#627: plugin MUST write a valid test-assessment.json with verdict=error,
# emit test_assessment.missing_input, and NOT invoke the LLM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: test_assessment fail-CLOSED (#627)"
setup_test_env "plugin-test-assessment-failclosed"

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
echo '{"schema_version":1,"run_id":"test","issue":"627","stage_statuses":{}}' > "$STATE_FILE"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE

# Seed plan + build-summary (these are NOT under test).
cat > "$ARTIFACTS_DIR/plan.json" <<'PJ'
{"schema_version":1,"title":"x","goal":"x","steps":[],"estimated_total_lines":0,"notes":""}
PJ
cat > "$ARTIFACTS_DIR/build-summary.json" <<'BS'
{"schema_version":1,"verdict":"pass","iterations":1,"terminated_reason":"complete"}
BS

# ─── Source plugin under test ─────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/test_assessment/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Mocks ────────────────────────────────────────────────────────────────────
# If apply_scope_redaction or route_to_model is invoked, the test FAILS.
_LLM_INVOKED_FILE="$TEST_TEMP_DIR/llm-invoked"
_REDACT_INVOKED_FILE="$TEST_TEMP_DIR/redact-invoked"
rm -f "$_LLM_INVOKED_FILE" "$_REDACT_INVOKED_FILE"

apply_scope_redaction() {
    printf 'INVOKED\n' >> "$_REDACT_INVOKED_FILE"
    cat "$1" > "$2"
    return 0
}
route_to_model() {
    printf 'INVOKED\n' >> "$_LLM_INVOKED_FILE"
    printf '{"schema_version":1,"verdict":"pass","summary":"FAKE","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","failure_summary_md":"FAKE","iter":1}\n'
    return 0
}

# Helper: reset artifact + event log between cases.
_reset_case() {
    rm -f "$ARTIFACTS_DIR/test-results.json"
    rm -f "$ARTIFACTS_DIR/test-assessment.json"
    rm -f "$ARTIFACTS_DIR/test-assessment.md"
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$_LLM_INVOKED_FILE" "$_REDACT_INVOKED_FILE"
}

# ─── Case A: missing test-results.json ────────────────────────────────────────
print_test_section "A: missing test-results.json"
_reset_case
# (file deliberately not created)

set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "A1 run returns rc=0 (writes error verdict)" "0" "$rc"
assert_file_exists "A2 test-assessment.json written" "$ARTIFACTS_DIR/test-assessment.json"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
assert_eq "A3 verdict=error" "error" "$(jq -r '.verdict' <<< "$content")"
assert_eq "A4 reason=test_results_missing" "test_results_missing" "$(jq -r '.reason' <<< "$content")"
assert_eq "A5 agrees_with_build_complete=false" "false" "$(jq -r '.agrees_with_build_complete' <<< "$content")"
assert_eq "A6 schema_version=1" "1" "$(jq -r '.schema_version' <<< "$content")"

if [[ ! -e "$_LLM_INVOKED_FILE" ]]; then
    assert_pass "A7 LLM NOT invoked"
else
    assert_fail "A7 LLM NOT invoked" "route_to_model was called"
fi
if [[ ! -e "$_REDACT_INVOKED_FILE" ]]; then
    assert_pass "A8 redaction NOT invoked (no prompt built)"
else
    assert_fail "A8 redaction NOT invoked" "apply_scope_redaction was called"
fi
assert_event_emitted "A9 test_assessment.missing_input emitted" \
    "$ZBUILD_EVENTS_JSONL" "test_assessment.missing_input"

# ─── Case B: malformed (non-JSON) test-results.json ───────────────────────────
print_test_section "B: malformed (non-JSON) test-results.json"
_reset_case
printf 'this is not json {{' > "$ARTIFACTS_DIR/test-results.json"

set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "B1 run returns rc=0" "0" "$rc"
assert_file_exists "B2 test-assessment.json written" "$ARTIFACTS_DIR/test-assessment.json"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
assert_eq "B3 verdict=error" "error" "$(jq -r '.verdict' <<< "$content")"
assert_eq "B4 reason=test_results_malformed" "test_results_malformed" "$(jq -r '.reason' <<< "$content")"
assert_eq "B5 agrees_with_build_complete=false" "false" "$(jq -r '.agrees_with_build_complete' <<< "$content")"

if [[ ! -e "$_LLM_INVOKED_FILE" ]]; then
    assert_pass "B6 LLM NOT invoked"
else
    assert_fail "B6 LLM NOT invoked" "route_to_model was called"
fi
assert_event_emitted "B7 test_assessment.missing_input emitted" \
    "$ZBUILD_EVENTS_JSONL" "test_assessment.missing_input"
# Verify reason=malformed in the event payload.
malformed_evt="$(grep '"type":"test_assessment.missing_input"' "$ZBUILD_EVENTS_JSONL" | head -1)"
assert_contains "B8 event carries reason=malformed" "$malformed_evt" '"reason":"malformed"'

# ─── Case C: empty file ───────────────────────────────────────────────────────
print_test_section "C: empty test-results.json"
_reset_case
: > "$ARTIFACTS_DIR/test-results.json"

set +e
test_assessment_run "test_assessment" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "C1 run returns rc=0" "0" "$rc"
assert_file_exists "C2 test-assessment.json written" "$ARTIFACTS_DIR/test-assessment.json"
content="$(cat "$ARTIFACTS_DIR/test-assessment.json")"
assert_eq "C3 verdict=error" "error" "$(jq -r '.verdict' <<< "$content")"
# Empty file is malformed JSON (jq empty rejects it).
assert_eq "C4 reason=test_results_malformed" "test_results_malformed" "$(jq -r '.reason' <<< "$content")"
if [[ ! -e "$_LLM_INVOKED_FILE" ]]; then
    assert_pass "C5 LLM NOT invoked"
else
    assert_fail "C5 LLM NOT invoked" "route_to_model was called"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
