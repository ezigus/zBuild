#!/usr/bin/env bash
# Tests: cycle-orchestrator divergence detection (ADR-021, #512)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — divergence detection (ADR-021)"
setup_test_env "cycle-divergence"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

H="$TEST_TEMP_DIR/history.jsonl"
_CYCLE_TRAP_CYCLE_ID="test"

_write_row() {
    printf '{"n":%d,"verdict":"fail","status":"complete","failure_count":%d,"ts":""}\n' "$1" "$2" >> "$H"
}

# T1: insufficient history (iter<K+1) → 1
: > "$H"
_CYCLE_TRAP_ITER=1
_write_row 1 1
set +e; _cycle_detect_divergence "$H" 2; rc=$?; set -e
assert_eq "iter=1, K=2 → no divergence (rc=1)" "1" "$rc"

# T2: 3 strictly increasing failure_counts → divergence (K=2)
: > "$H"
_CYCLE_TRAP_ITER=3
_write_row 1 1
_write_row 2 3
_write_row 3 5
set +e; _cycle_detect_divergence "$H" 2; rc=$?; set -e
assert_eq "strictly increasing K=2 → divergence (rc=0)" "0" "$rc"

# T3: flat sequence → no divergence
: > "$H"
_CYCLE_TRAP_ITER=3
_write_row 1 2
_write_row 2 2
_write_row 3 2
set +e; _cycle_detect_divergence "$H" 2; rc=$?; set -e
assert_eq "flat sequence → no divergence (rc=1)" "1" "$rc"

# T4: decreasing then increasing → no divergence (need K consec positive deltas)
: > "$H"
_CYCLE_TRAP_ITER=3
_write_row 1 5
_write_row 2 3
_write_row 3 4
set +e; _cycle_detect_divergence "$H" 2; rc=$?; set -e
assert_eq "mixed (decrease then increase) → no divergence (rc=1)" "1" "$rc"

# T5: K=1 with one positive delta → divergence
: > "$H"
_CYCLE_TRAP_ITER=2
_write_row 1 1
_write_row 2 2
set +e; _cycle_detect_divergence "$H" 1; rc=$?; set -e
assert_eq "K=1 single positive delta → divergence (rc=0)" "0" "$rc"

print_test_results
