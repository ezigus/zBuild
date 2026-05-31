#!/usr/bin/env bash
# Tests: cycle-orchestrator _cycle_apply_feedback (ADR-021, #512)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — feedback wiring (ADR-021)"
setup_test_env "cycle-feedback"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

_CYCLE_TRAP_CYCLE_ID="build-test"
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR/artifacts/test"

# T1: from-artifact present + required=false → copy succeeds, returns 0
echo "test artifact" > "$STATE_DIR/artifacts/test/primary.txt"
_CYCLE_FEEDBACK=("test:primary.txt|build:prior_test_result:false")
set +e; _cycle_apply_feedback 2 "$STATE_DIR"; rc=$?; set -e
assert_eq "feedback copy succeeds → rc=0" "0" "$rc"
assert_file_exists "feedback file copied to iter-2/feedback dir" \
    "$STATE_DIR/cycle-build-test/iter-2/feedback/prior_test_result.txt"
assert_eq "ZBUILD_CYCLE_FEEDBACK_DIR exported" \
    "$STATE_DIR/cycle-build-test/iter-2/feedback" "$ZBUILD_CYCLE_FEEDBACK_DIR"

# T2: from-artifact MISSING + required=true → rc=1 + emits cycle.feedback.missing
rm -f "$STATE_DIR/artifacts/test/primary.txt"
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_FEEDBACK=("test:primary.txt|build:prior_test_result:true")
set +e; _cycle_apply_feedback 3 "$STATE_DIR"; rc=$?; set -e
assert_eq "missing required from-field → rc=1 (fail-closed)" "1" "$rc"
assert_contains "emits cycle.feedback.missing" "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.feedback.missing"

# T3: from-artifact MISSING + required=false → rc=0 (warn only), event still emitted
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_FEEDBACK=("test:primary.txt|build:prior_test_result:false")
set +e; _cycle_apply_feedback 4 "$STATE_DIR"; rc=$?; set -e
assert_eq "missing optional from-field → rc=0 (continue)" "0" "$rc"
assert_contains "still emits cycle.feedback.missing event" "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.feedback.missing"

# T4: empty feedback list → rc=0, no events
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_FEEDBACK=()
set +e; _cycle_apply_feedback 5 "$STATE_DIR"; rc=$?; set -e
assert_eq "empty feedback list → rc=0" "0" "$rc"

print_test_results
