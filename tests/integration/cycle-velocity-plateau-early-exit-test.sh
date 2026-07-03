#!/usr/bin/env bash
# Integration test: velocity_plateau NO-LONGER early-exits (#845 → #1208)
#
# #1208 removed velocity_plateau/plateau/divergence as EARLY terminators ("run
# all tries" — the only fatal condition is exhausting max_iterations without a
# clean, passing convergence). This test now asserts the REVERSED contract: a
# flat-failing cycle runs ALL its iterations (does NOT bail at the velocity
# window) and terminates BY-SEVERITY at exhaustion — failing tests → rc=8. No
# cycle.plateau early-terminator event fires (the detector function still exists
# for potential reuse but is no longer wired into the cascade).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — velocity_plateau early exit (ADR-021 #845)"
setup_test_env "cycle-velocity-plateau-int"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

FIXT="$REPO_ROOT/tests/fixtures/templates"
STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

_seed_state() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
}

# Mock dispatch hook: always returns failure_count=11 (flat velocity), never
# converges so the velocity_plateau detector must fire the early exit.
cycle_dispatch_stage() {
    local stage="$1"
    _CYCLE_DISPATCH_VERDICT="fail"
    _CYCLE_DISPATCH_STATUS="failed"
    _CYCLE_DISPATCH_FAILURE_COUNT=11
    return 1
}

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

# T1: flat-failing velocity does NOT early-exit — runs to max_iterations=5 and
# terminates by-severity (failing tests → rc=8). NOT reason=plateau at iter 2.
_seed_state
load_template "$FIXT/cycle-velocity-plateau.yaml"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T1: no early exit — exhausted with failing tests → rc=8 (by-severity)" "8" "$rc"
assert_eq "T1: ran ALL 5 iterations (velocity plateau no longer bails at window=2)" \
    "5" "$_CYCLE_LAST_ITERATIONS"
if [[ "$_CYCLE_LAST_TERMINATED_REASON" == "plateau" ]]; then
    assert_fail "T1: reason is NOT plateau (early terminator removed)" "$_CYCLE_LAST_TERMINATED_REASON"
else
    assert_pass "T1: reason is not plateau (got $_CYCLE_LAST_TERMINATED_REASON)"
fi
if grep -q '"cycle.plateau"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "T1: no cycle.plateau early-terminator event" "cycle.plateau emitted"
else
    assert_pass "T1: no cycle.plateau early-terminator event (detector unwired)"
fi

print_test_results
