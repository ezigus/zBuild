#!/usr/bin/env bash
# Integration test: build_test_cycle terminates at iter 1 when the test stage
# fails to write test-results.json — test_assessment now fail-CLOSES (#627).
#
# Before #627: test_assessment substituted '{}' for missing test-results.json
# and called the LLM, producing fabricated assessments and letting the cycle
# burn all 3 iterations on hallucinated verdicts.
# After  #627: test_assessment writes verdict=error → _cycle_detect_blocked
# fires at iter 1 → cycle.blocked emitted, orchestrator rc=5.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cycle blocks at iter 1 when test-results.json missing (#627)"
setup_test_env "cycle-blocks-missing-test-results"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/plugins/agent/test_assessment/plugin.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
ART_DIR="$ZBUILD_STATE_DIR/artifacts"
mkdir -p "$ART_DIR"

# Required scaffolding for test_assessment_run_inner.
cat > "$ZBUILD_STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE
cat > "$ART_DIR/plan.json" <<'PJ'
{"schema_version":1,"title":"x","goal":"x","steps":[],"estimated_total_lines":0,"notes":""}
PJ

# ─── Mocks: redaction + LLM. If route_to_model is invoked, the test FAILS. ──
_LLM_INVOKED_FILE="$TEST_TEMP_DIR/llm-invoked"
rm -f "$_LLM_INVOKED_FILE"
apply_scope_redaction() {
    cat "$1" > "$2"
    return 0
}
route_to_model() {
    printf 'INVOKED\n' >> "$_LLM_INVOKED_FILE"
    # If this is somehow reached, the cycle would NOT block — return a pass
    # verdict so the failure surface is the assert_no_event below.
    printf '%s\n' '{"schema_version":1,"verdict":"pass","summary":"FAKE","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"unknown","failure_summary_md":"FAKE","iter":1}'
    return 0
}

# ─── Cycle dispatch mock ──────────────────────────────────────────────────────
# - build: writes a passing build-summary.json (so iter advances to test).
# - test:  DOES NOT write test-results.json (simulates the crashed-test stage
#          that prompted #627).
# - test_assessment: invokes the REAL plugin's inner function. With #627 in
#          place, missing test-results.json → verdict=error → blocked.
cycle_dispatch_stage() {
    local stage="$1"
    _CYCLE_DISPATCH_VERDICT=""
    _CYCLE_DISPATCH_STATUS=""
    local manifest art rc=0
    case "$stage" in
        build)
            manifest="$REPO_ROOT/plugins/agent/build/manifest.yaml"
            art="$ART_DIR/build-summary.json"
            printf '%s\n' '{"verdict":"pass","scope_violation":false,"iterations":1,"terminated_reason":"complete"}' > "$art"
            ;;
        test)
            # NOTE: intentionally NOT writing test-results.json (this is the
            # crashed-test simulation). The runner_read_stage_verdict call
            # will resolve to "missing", but the cycle's until-stage is
            # test_assessment, so the iteration continues into test_assessment.
            manifest="$REPO_ROOT/plugins/tool/test/manifest.yaml"
            ;;
        test_assessment)
            manifest="$REPO_ROOT/plugins/agent/test_assessment/manifest.yaml"
            # Drive the REAL plugin inner function — this is the code under test.
            _test_assessment_run_inner \
                "$ZBUILD_STATE_DIR/scope-manifest.md" \
                "$ART_DIR/test-results.json" \
                "$ART_DIR/plan.json" \
                "$ART_DIR/build-summary.json" \
                "$ART_DIR/test-assessment.json" \
                "$ART_DIR/test-assessment.md" \
                "$ART_DIR" \
                "$ZBUILD_STATE_DIR" \
                >/dev/null 2>&1 || rc=$?
            ;;
        *)
            _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"; return 0
            ;;
    esac
    _CYCLE_DISPATCH_VERDICT="$(runner_read_stage_verdict \
        "$ZBUILD_STATE_DIR" "$manifest" "$stage" "$rc" 2>/dev/null || echo "missing")"
    if [[ $rc -eq 0 ]]; then
        _CYCLE_DISPATCH_STATUS="complete"
    else
        _CYCLE_DISPATCH_STATUS="failed"
    fi
    return $rc
}

_seed_state() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
    rm -f "$ART_DIR/test-results.json" \
          "$ART_DIR/test-assessment.json" \
          "$ART_DIR/test-assessment.md" \
          "$ART_DIR/build-summary.json"
}

# Build a minimal cycle template inline: build → test → test_assessment.
TPL_FILE="$TEST_TEMP_DIR/cycle.yaml"
cat > "$TPL_FILE" <<'TPL'
id: cycle-missing-test-results
name: Cycle for #627 — test stage crashes (no test-results.json)
defaults:
  strategy: fanout
stages:
  - id: build_test_cycle
    type: cycle
    stages: [build, test, test_assessment]
    until:
      stage: test_assessment
      field: verdict
      op: eq
      value: pass
    max_iterations: 3
    on_max: continue

stage_definitions:
  build:
    roles: [builder]
  test:
    roles: [tester]
  test_assessment:
    roles: [test_assessment]
TPL

_seed_state
load_template "$TPL_FILE"
set +e
cycle_orchestrator_run "build_test_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"
rc=$?
set -e

assert_eq "T1: orchestrator rc=5 (blocked)" "5" "$rc"
assert_eq "T2: terminated at iter 1 (NOT all 3)" "1" "$_CYCLE_LAST_ITERATIONS"
assert_eq "T3: reason=blocked" "blocked" "$_CYCLE_LAST_TERMINATED_REASON"
assert_event_emitted "T4: cycle.blocked event fired" \
    "$ZBUILD_EVENTS_JSONL" "cycle.blocked"
assert_event_emitted "T5: cycle.complete event fired" \
    "$ZBUILD_EVENTS_JSONL" "cycle.complete"

blocked_evt="$(grep '"type":"cycle.blocked"' "$ZBUILD_EVENTS_JSONL" | head -1)"
assert_contains "T6: cycle.blocked stage=test_assessment" "$blocked_evt" '"stage":"test_assessment"'
assert_contains "T7: cycle.blocked verdict=error" "$blocked_evt" '"verdict":"error"'

# The fail-CLOSED guarantee: LLM never invoked.
if [[ ! -e "$_LLM_INVOKED_FILE" ]]; then
    assert_pass "T8: route_to_model NEVER invoked (fail-CLOSED, no fabricated assessment)"
else
    assert_fail "T8: route_to_model NEVER invoked" "LLM was called despite missing test-results.json"
fi

# Exactly one iteration ran — proves the cycle did NOT burn 3 hallucinations.
ic_count=$(grep -c '"type":"cycle.iteration.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_eq "T9: exactly 1 iteration.complete (no retries on structural error)" \
    "1" "$ic_count"

# The fail-CLOSED artifact was actually written.
assert_file_exists "T10: test-assessment.json written by fail-CLOSED path" \
    "$ART_DIR/test-assessment.json"
content="$(cat "$ART_DIR/test-assessment.json")"
assert_eq "T11: test-assessment.json verdict=error" "error" "$(jq -r '.verdict' <<< "$content")"
assert_eq "T12: test-assessment.json reason=test_results_missing" \
    "test_results_missing" "$(jq -r '.reason' <<< "$content")"

print_test_results
