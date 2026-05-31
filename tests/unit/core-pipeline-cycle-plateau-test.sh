#!/usr/bin/env bash
# Tests: cycle-orchestrator plateau detection (ADR-021, #512)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — plateau detection (ADR-021)"
setup_test_env "cycle-plateau"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

H="$TEST_TEMP_DIR/history.jsonl"
_CYCLE_TRAP_CYCLE_ID="test"

# Helper: write N rows with given verdict/failure_count
_write_row() {
    local n="$1" v="$2" fc="$3"
    printf '{"n":%d,"verdict":"%s","status":"complete","failure_count":%d,"ts":""}\n' \
        "$n" "$v" "$fc" >> "$H"
}

# T1: iter=1 → SKIP (insufficient history)
: > "$H"
_CYCLE_TRAP_ITER=1
_write_row 1 fail 2
set +e; _cycle_detect_plateau "$H" 3; rc=$?; set -e
assert_eq "iter=1 → plateau skipped (rc=1)" "1" "$rc"
assert_contains "iter=1 emits cycle.plateau.skipped" "$(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null)" "cycle.plateau.skipped"

# T2: history shorter than window → SKIP
: > "$H"; : > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_ITER=2
_write_row 1 fail 2
_write_row 2 fail 2
set +e; _cycle_detect_plateau "$H" 3; rc=$?; set -e
assert_eq "history<window → plateau skipped (rc=1)" "1" "$rc"

# T3: 3 identical rows → plateau detected
: > "$H"; : > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_ITER=3
_write_row 1 fail 2
_write_row 2 fail 2
_write_row 3 fail 2
set +e; _cycle_detect_plateau "$H" 3; rc=$?; set -e
assert_eq "3 identical rows → plateau (rc=0)" "0" "$rc"

# T4: last 3 differ → no plateau
: > "$H"; : > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_ITER=3
_write_row 1 fail 2
_write_row 2 fail 1
_write_row 3 fail 2
set +e; _cycle_detect_plateau "$H" 3; rc=$?; set -e
assert_eq "differing rows → no plateau (rc=1)" "1" "$rc"

# T5: window=2 — 2 identical rows → plateau
: > "$H"; : > "$ZBUILD_EVENTS_JSONL"
_CYCLE_TRAP_ITER=2
_write_row 1 pass 0
_write_row 2 pass 0
set +e; _cycle_detect_plateau "$H" 2; rc=$?; set -e
assert_eq "window=2, 2 identical rows → plateau (rc=0)" "0" "$rc"

print_test_results
