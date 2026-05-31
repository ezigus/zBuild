#!/usr/bin/env bash
# Integration test: end-to-end cycle blocked path with REAL verdict resolution
# (#550 review followup).
#
# Regression coverage for the silent failure where PR #553 wrote
# test-results.json verdict=error but runner_read_stage_verdict collapsed it
# to "fail" via verdict_classify, so _cycle_detect_blocked never fired. The
# fix preserves error/corrupt_diff/block as raw verdicts.
#
# This test exercises the FULL chain:
#   1. test plugin emits {"verdict":"error"} via test-results.json
#   2. runner_read_stage_verdict resolves the verdict from the manifest's
#      primary output (the real path the runner uses)
#   3. The resolved verdict feeds into the verdicts blob
#   4. _cycle_detect_blocked fires on raw "error"
#   5. cycle_orchestrator_run aborts at iter 1 (not 3), rc=5, reason=blocked
#
# Existing core-pipeline-cycle-blocked-integration-test.sh stubs
# cycle_dispatch_stage directly and hard-codes _CYCLE_DISPATCH_VERDICT, so
# it does NOT catch a regression in runner_read_stage_verdict — that's what
# this test adds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle blocked — real verdict-resolution path (#550)"
setup_test_env "cycle-blocked-real"

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

# ─── Sub-test A: runner_read_stage_verdict returns raw error/corrupt_diff/block
# directly from real plugin manifest path (not the unit-test synthetic manifest).
print_test_section "real test-plugin manifest → raw verdict pass-through"

ART_DIR="$ZBUILD_STATE_DIR/artifacts"
mkdir -p "$ART_DIR"

TEST_MANIFEST="$REPO_ROOT/plugins/tool/test/manifest.yaml"
[[ -f "$TEST_MANIFEST" ]] || { echo "test plugin manifest missing: $TEST_MANIFEST"; exit 1; }

# A1: verdict=error (mirrors what PR #553 plugin.sh writes on diff_apply_failed)
printf '%s\n' '{"verdict":"error","reason":"diff_apply_failed","tests_run":0,"tests_passed":0,"tests_failed":0}' \
    > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$ZBUILD_STATE_DIR" "$TEST_MANIFEST" "test" 0)"
assert_eq "A1: real test plugin verdict=error → 'error' (NOT 'fail')" "error" "$got"

# A2: verdict=fail still classifies to 'fail' (no regression)
printf '%s\n' '{"verdict":"fail","tests_run":3,"tests_passed":2,"tests_failed":1}' \
    > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$ZBUILD_STATE_DIR" "$TEST_MANIFEST" "test" 0)"
assert_eq "A2: real test plugin verdict=fail → 'fail' (no regression)" "fail" "$got"

# A3: verdict=pass still classifies to 'pass'
printf '%s\n' '{"verdict":"pass","tests_run":3,"tests_passed":3,"tests_failed":0}' \
    > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$ZBUILD_STATE_DIR" "$TEST_MANIFEST" "test" 0)"
assert_eq "A3: real test plugin verdict=pass → 'pass'" "pass" "$got"

# ─── Sub-test B: end-to-end cycle abort with real verdict reader in the loop
print_test_section "cycle aborts at iter 1 when test verdict=error is read from artifact"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
FIXT="$REPO_ROOT/tests/fixtures/templates"

_seed_state() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
}

# cycle_dispatch_stage mock that goes through runner_read_stage_verdict for
# real — exactly the path runner.sh:931 uses. This is the integration that
# the silent-failure regression slipped past.
cycle_dispatch_stage() {
    local stage="$1"
    # iter ($2) is intentionally unused — this mock returns the same
    # verdict on every iteration; the cycle aborts at iter 1 via the
    # blocked predicate.
    _CYCLE_DISPATCH_VERDICT=""
    _CYCLE_DISPATCH_STATUS=""
    local manifest art rc=0
    case "$stage" in
        build)
            manifest="$REPO_ROOT/plugins/agent/build/manifest.yaml"
            art="$ZBUILD_STATE_DIR/artifacts/build-summary.json"
            mkdir -p "$(dirname "$art")"
            printf '%s\n' '{"verdict":"pass","scope_violation":false}' > "$art"
            ;;
        test)
            manifest="$REPO_ROOT/plugins/tool/test/manifest.yaml"
            art="$ZBUILD_STATE_DIR/artifacts/test-results.json"
            mkdir -p "$(dirname "$art")"
            # Mirror the PR #553 diff_apply_failed write exactly: plugin
            # writes verdict=error to the artifact and returns rc=0 so the
            # pipeline engine reads the verdict from the artifact (per the
            # test plugin's documented contract — "always exits 0 so the
            # pipeline engine reads the verdict from the artifact rather
            # than the plugin exit code").
            printf '%s\n' \
                '{"verdict":"error","reason":"diff_apply_failed","tests_run":0,"tests_passed":0,"tests_failed":0}' \
                > "$art"
            rc=0
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

_seed_state
load_template "$FIXT/cycle-blocked.yaml"
set +e
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
rc=$?
set -e

assert_eq "B1: orchestrator rc=5 (blocked)" "5" "$rc"
assert_eq "B2: terminated at iter 1 (only ONE iteration ran)" "1" "$_CYCLE_LAST_ITERATIONS"
assert_eq "B3: reason=blocked" "blocked" "$_CYCLE_LAST_TERMINATED_REASON"
assert_event_emitted "B4: cycle.blocked event fired" \
    "$ZBUILD_EVENTS_JSONL" "cycle.blocked"
assert_event_emitted "B5: cycle.complete event fired" \
    "$ZBUILD_EVENTS_JSONL" "cycle.complete"

# Verify the blocked event carries the originating stage + raw verdict.
blocked_evt="$(grep '"type":"cycle.blocked"' "$ZBUILD_EVENTS_JSONL" | head -1)"
assert_contains "B6: cycle.blocked stage=test" "$blocked_evt" '"stage":"test"'
assert_contains "B7: cycle.blocked verdict=error (raw, NOT 'fail')" \
    "$blocked_evt" '"verdict":"error"'

# Negative-coverage: cycle.complete reason MUST be "blocked", NOT "max_iterations"
# (which is what would happen if the bug regressed and the cycle ran all 3
# iterations).
complete_evt="$(grep '"type":"cycle.complete"' "$ZBUILD_EVENTS_JSONL" | head -1)"
assert_contains "B8: cycle.complete reason=blocked (NOT max_iterations)" \
    "$complete_evt" '"reason":"blocked"'

# Exactly one iteration.complete fired (proves no extra retries).
ic_count=$(grep -c '"type":"cycle.iteration.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_eq "B9: exactly 1 cycle.iteration.complete (no retry of structural error)" \
    "1" "$ic_count"

print_test_results
