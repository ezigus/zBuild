#!/usr/bin/env bash
# Tests: _cycle_detect_velocity_plateau (ADR-021, #845)
# Validates the velocity-plateau detector in isolation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — velocity_plateau detection (ADR-021 #845)"
setup_test_env "cycle-velocity-plateau-unit"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

H="$TEST_TEMP_DIR/history.jsonl"
_CYCLE_TRAP_CYCLE_ID="test"

# Helper: append a row with given failure_count
_write_row() {
    local n="$1" fc="$2"
    printf '{"n":%d,"verdict":"fail","status":"failed","failure_count":%d,"ts":""}\n' \
        "$n" "$fc" >> "$H"
}

# T1: iter=1 → SKIP (insufficient history)
: > "$H"; : > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_ITER=1
_write_row 1 5
set +e; _cycle_detect_velocity_plateau "$H" 2; rc=$?; set -e
assert_eq "T1: iter=1 → velocity_plateau skipped (rc=1)" "1" "$rc"
assert_contains "T1: emits cycle.plateau.skipped" "$(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null)" "cycle.plateau.skipped"

# T2: history shorter than window → SKIP
: > "$H"; : > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_ITER=2
_write_row 1 5
set +e; _cycle_detect_velocity_plateau "$H" 2; rc=$?; set -e
assert_eq "T2: history<window → velocity_plateau skipped (rc=1)" "1" "$rc"

# T3: K identical failure_counts → plateau
: > "$H"; : > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_ITER=3
_write_row 1 5
_write_row 2 5
_write_row 3 5
set +e; _cycle_detect_velocity_plateau "$H" 3; rc=$?; set -e
assert_eq "T3: identical failure_counts (window=3) → plateau (rc=0)" "0" "$rc"
assert_eq "T3: evidence=velocity_flat" "velocity_flat" "$_CYCLE_LAST_PLATEAU_EVIDENCE"

# T4: failure_count strictly decreasing → no plateau
: > "$H"; : > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_ITER=3
_write_row 1 5
_write_row 2 4
_write_row 3 3
set +e; _cycle_detect_velocity_plateau "$H" 3; rc=$?; set -e
assert_eq "T4: strictly decreasing failure_count → no plateau (rc=1)" "1" "$rc"

# T5: mixed (decrease then flat) → no plateau across full window
: > "$H"; : > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_ITER=3
_write_row 1 5
_write_row 2 4
_write_row 3 4
set +e; _cycle_detect_velocity_plateau "$H" 3; rc=$?; set -e
assert_eq "T5: decrease then flat across full window → no plateau (rc=1)" "1" "$rc"

# T6: window=2, two identical rows → plateau
: > "$H"; : > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_ITER=2
_write_row 1 7
_write_row 2 7
set +e; _cycle_detect_velocity_plateau "$H" 2; rc=$?; set -e
assert_eq "T6: window=2, two identical rows → plateau (rc=0)" "0" "$rc"
assert_eq "T6: evidence=velocity_flat" "velocity_flat" "$_CYCLE_LAST_PLATEAU_EVIDENCE"

# T7: failure_count increasing (negative velocity) → plateau
: > "$H"; : > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_ITER=3
_write_row 1 3
_write_row 2 5
_write_row 3 8
set +e; _cycle_detect_velocity_plateau "$H" 3; rc=$?; set -e
assert_eq "T7: failure_count increasing → plateau (rc=0)" "0" "$rc"
assert_eq "T7: evidence=velocity_flat" "velocity_flat" "$_CYCLE_LAST_PLATEAU_EVIDENCE"

print_test_results
