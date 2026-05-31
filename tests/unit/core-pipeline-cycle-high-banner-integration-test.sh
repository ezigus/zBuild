#!/usr/bin/env bash
# Tests: cycle-orchestrator HIGH-event banner integration (#526).
# Verifies BOTH a JSONL event AND a stderr WARN banner are emitted when one
# of the 5 HIGH-severity cycle.* events fires, and that informational events
# (cycle.plateau.skipped etc.) do NOT trigger a banner.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — HIGH event banner integration (#526)"
setup_test_env "cycle-high-banner-int"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

_CYCLE_TRAP_CYCLE_ID="build-test"
_CYCLE_TRAP_ITER=2
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR"

# ─── S1: cycle.feedback.missing → JSONL event AND stderr WARN banner ─────────
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_FEEDBACK=("test:primary.txt|build:prior_test_result:true")
err="$(_cycle_apply_feedback 3 "$STATE_DIR" 2>&1 >/dev/null || true)"
jsonl="$(cat "$ZBUILD_EVENTS_JSONL")"
assert_contains "cycle.feedback.missing JSONL event recorded" "$jsonl" "cycle.feedback.missing"
assert_contains "cycle.feedback.missing stderr banner emitted" "$err" "⚠"
assert_contains "stderr banner names event type" "$err" "cycle.feedback.missing"

# ─── S2: cycle.iteration.verdict_missing → both emitted ──────────────────────
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_UNTIL_STAGE="test"; _CYCLE_UNTIL_FIELD="verdict"
_CYCLE_UNTIL_OP="eq"; _CYCLE_UNTIL_VALUE="pass"
err2="$(_cycle_check_until '{}' 2>&1 >/dev/null || true)"
jsonl2="$(cat "$ZBUILD_EVENTS_JSONL")"
assert_contains "cycle.iteration.verdict_missing JSONL event" "$jsonl2" "cycle.iteration.verdict_missing"
assert_contains "cycle.iteration.verdict_missing stderr banner" "$err2" "cycle.iteration.verdict_missing"
assert_contains "verdict_missing banner has ⚠" "$err2" "⚠"

# ─── S3: cycle.metric.invalid → both emitted ─────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
err3="$(_cycle_detect_plateau "$STATE_DIR/none.jsonl" "bogus" 2>&1 >/dev/null || true)"
jsonl3="$(cat "$ZBUILD_EVENTS_JSONL")"
assert_contains "cycle.metric.invalid JSONL event" "$jsonl3" "cycle.metric.invalid"
assert_contains "cycle.metric.invalid stderr banner" "$err3" "cycle.metric.invalid"

# ─── S4: cycle.history.lost → both emitted (append to unwritable file) ───────
: > "$ZBUILD_EVENTS_JSONL"
unwritable="$TEST_TEMP_DIR/nodir/history.jsonl"
mkdir -p "$TEST_TEMP_DIR/nodir"
chmod 000 "$TEST_TEMP_DIR/nodir"
err4="$(_cycle_record_iter_outcome "$unwritable" 1 pass complete 0 2>&1 >/dev/null || true)"
chmod 755 "$TEST_TEMP_DIR/nodir"
jsonl4="$(cat "$ZBUILD_EVENTS_JSONL")"
assert_contains "cycle.history.lost JSONL event" "$jsonl4" "cycle.history.lost"
assert_contains "cycle.history.lost stderr banner" "$err4" "cycle.history.lost"

# ─── S5: informational event (cycle.plateau.skipped) does NOT emit banner ────
: > "$ZBUILD_EVENTS_JSONL"
# Force the skip path: iter<2.
_CYCLE_TRAP_ITER=1
err5="$(_cycle_detect_plateau "$STATE_DIR/none.jsonl" 3 2>&1 >/dev/null || true)"
jsonl5="$(cat "$ZBUILD_EVENTS_JSONL")"
assert_contains "cycle.plateau.skipped JSONL event still recorded" "$jsonl5" "cycle.plateau.skipped"
if grep -qF "⚠" <<< "$err5"; then
    assert_fail "informational event has no banner" "stderr unexpectedly contained ⚠: $err5"
else
    assert_pass "informational event has no banner"
fi

print_test_results
