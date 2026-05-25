#!/usr/bin/env bash
# Tests: CI/CLI parity — pipeline core produces identical output regardless of GITHUB_ACTIONS env
# ADR-010: zbuild behavior is environmentally agnostic for the pipeline core
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/scripts/lib/golden.sh"

print_test_header "CI/CLI parity — engine behavior is environmentally agnostic (ADR-010)"
setup_test_env "parity-local-vs-ci"

FIXTURE="$REPO_ROOT/tests/golden/parity/run-fixture.sh"
RUN1_DIR="$TEST_TEMP_DIR/run-local"
RUN2_DIR="$TEST_TEMP_DIR/run-ci"
BIN_DIR="$TEST_TEMP_DIR/bin"
mkdir -p "$RUN1_DIR/events" "$RUN2_DIR/events" "$BIN_DIR"

# ── Test 1: fixture exists and is executable ──────────────────────────────────
if [[ -x "$FIXTURE" ]]; then
    assert_pass "fixture script exists and is executable"
else
    assert_fail "fixture script exists and is executable" "not found or not executable: $FIXTURE"
fi

# ── Test 2: local mode run exits 0 ───────────────────────────────────────────
# Unset any CI env vars that might bleed in from the calling environment
set +e
(
    unset GITHUB_ACTIONS CI GITHUB_STEP_SUMMARY RUNNER_OS 2>/dev/null || true
    FIXTURE_STATE_DIR="$RUN1_DIR" FIXTURE_BIN_DIR="$BIN_DIR" \
        bash "$FIXTURE" >/dev/null 2>&1
)
local_rc=$?
set -e
assert_eq "fixture runs exit 0 in local mode" "0" "$local_rc"

# ── Test 3: local run produces pipeline-state.json ───────────────────────────
assert_file_exists "pipeline-state.json created (local)" "$RUN1_DIR/pipeline-state.json"

# ── Test 4: local run produces events.jsonl ──────────────────────────────────
assert_file_exists "events.jsonl created (local)" "$RUN1_DIR/events/events.jsonl"

# ── Test 5: CI mode run exits 0 ──────────────────────────────────────────────
SUMMARY_FILE="$TEST_TEMP_DIR/step-summary.md"
set +e
FIXTURE_STATE_DIR="$RUN2_DIR" FIXTURE_BIN_DIR="$BIN_DIR" \
GITHUB_ACTIONS=true CI=true RUNNER_OS=Linux \
GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
ZBUILD_OUTPUT_GH_COMMENT=0 ZBUILD_OUTPUT_GH_CHECK_RUN=0 \
    bash "$FIXTURE" >/dev/null 2>&1
ci_rc=$?
set -e
assert_eq "fixture runs exit 0 in CI mode" "0" "$ci_rc"

# ── Test 6: pipeline final status is "complete" in both modes ────────────────
local_status="$(jq -r '.status // empty' "$RUN1_DIR/pipeline-state.json" 2>/dev/null || true)"
ci_status="$(jq -r '.status // empty' "$RUN2_DIR/pipeline-state.json" 2>/dev/null || true)"
assert_eq "local run pipeline status=complete" "complete" "$local_status"
assert_eq "CI run pipeline status=complete" "complete" "$ci_status"

# ── Test 7: event type sequence is identical in local and CI modes ────────────
local_events="$(jq -r '.type' "$RUN1_DIR/events/events.jsonl" 2>/dev/null || true)"
ci_events="$(jq -r '.type' "$RUN2_DIR/events/events.jsonl" 2>/dev/null || true)"
assert_eq "event type sequence identical in local and CI modes" "$local_events" "$ci_events"

# ── Test 8: stage_statuses map is identical in both modes ────────────────────
local_stages="$(jq -Sc '.stage_statuses' "$RUN1_DIR/pipeline-state.json" 2>/dev/null || true)"
ci_stages="$(jq -Sc '.stage_statuses' "$RUN2_DIR/pipeline-state.json" 2>/dev/null || true)"
assert_eq "stage_statuses identical in local and CI modes" "$local_stages" "$ci_stages"

# ── Test 9: event sequence matches golden snapshot ───────────────────────────
if ! assert_golden "parity/event-sequence" "$local_events"; then
    assert_fail "event sequence matches golden snapshot" "golden mismatch (run UPDATE_GOLDEN=1 to regenerate)"
else
    assert_pass "event sequence matches golden snapshot"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
