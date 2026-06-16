#!/usr/bin/env bash
# Integration test: velocity_plateau early-exit in cycle_orchestrator_run (#845)
#
# Stubs cycle_dispatch_stage to always return failure_count=11 (flat velocity).
# Configures max_iterations=5 and velocity_plateau.window=2 via fixture.
# Asserts the cycle exits after 2 iterations with reason=plateau and rc=2,
# verifying it did NOT run to max_iterations=5.
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

# T1: velocity_plateau early exit — flat failure_count=11, window=2, max=5
# Cycle must exit after iteration 2 (plateau) NOT iteration 5 (max_iterations).
_seed_state
load_template "$FIXT/cycle-velocity-plateau.yaml"
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T1: orchestrator rc=2 (plateau)" "2" "$rc"
assert_eq "T1: reason=plateau" "plateau" "$_CYCLE_LAST_TERMINATED_REASON"
assert_eq "T1: iterations=2 (not max_iterations=5)" "2" "$_CYCLE_LAST_ITERATIONS"
assert_event_emitted "T1: cycle.plateau emitted" "$ZBUILD_EVENTS_JSONL" "cycle.plateau"

# Verify cycle.plateau carries evidence=velocity_flat
plateau_event="$(grep '"cycle.plateau"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1)"
assert_contains "T1: evidence=velocity_flat in plateau event" "$plateau_event" "velocity_flat"
# Pin the streak too: it MUST report the velocity window (2), not the tuple
# window — guards the bug where the emit hardcoded _CYCLE_PLATEAU_WINDOW
# regardless of which detector fired (Copilot review on PR #914).
assert_contains "T1: streak=2 (velocity window, not tuple window) in plateau event" \
    "$plateau_event" '"streak":"2"'

print_test_results
