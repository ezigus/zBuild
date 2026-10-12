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

# T1: the engine keeps no copy of a stage's output between tries. A feedback
# edge only says the output may flow back; the consumer reads the producer's
# latest output (#1932's run judged a design that had already been replaced).
echo "test artifact" > "$STATE_DIR/artifacts/test/primary.txt"
_CYCLE_FEEDBACK=("test:primary.txt|build:prior_test_result:false")
unset ZBUILD_CYCLE_FEEDBACK_DIR
set +e; _cycle_apply_feedback 2 "$STATE_DIR"; rc=$?; set -e
assert_eq "present from-artifact → rc=0" "0" "$rc"
if [[ -e "$STATE_DIR/cycle-build-test/iter-2/feedback" ]]; then
    assert_fail "[ADR-021 §3] no feedback copy is made" \
        "$(find "$STATE_DIR/cycle-build-test" -type f | tr '\n' ' ')"
else
    assert_pass "[ADR-021 §3] no feedback copy is made"
fi
assert_eq "[ADR-021 §3] no feedback dir is exported" "" "${ZBUILD_CYCLE_FEEDBACK_DIR:-}"

# T2: from-artifact MISSING + required=true → rc=1 + emits cycle.feedback.missing
rm -f "$STATE_DIR/artifacts/test/primary.txt"
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_FEEDBACK=("test:primary.txt|build:prior_test_result:true")
set +e; _cycle_apply_feedback 3 "$STATE_DIR"; rc=$?; set -e
assert_eq "missing required from-field → rc=1 (fail-closed)" "1" "$rc"
assert_contains "[SPEC-2] required=true absent emits cycle.feedback.missing" "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.feedback.missing"

# T3: from-artifact MISSING + required=false → rc=0, emits cycle.feedback.absent (not .missing)
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_FEEDBACK=("test:primary.txt|build:prior_test_result:false")
set +e; _cycle_apply_feedback 4 "$STATE_DIR"; rc=$?; set -e
assert_eq "missing optional from-field → rc=0 (continue)" "0" "$rc"
assert_contains "[SPEC-1] optional absent emits cycle.feedback.absent" "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.feedback.absent"

# T4: empty feedback list → rc=0, no events
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_FEEDBACK=()
set +e; _cycle_apply_feedback 5 "$STATE_DIR"; rc=$?; set -e
assert_eq "empty feedback list → rc=0" "0" "$rc"

# T5: SPEC-5 regression — optional absent fires no ⚠ banner (cycle.feedback.absent is not HIGH)
# At baseline this fails: cycle.feedback.missing fires for optional absent AND is bannered.
: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_FEEDBACK=("test:primary.txt|build:prior_test_result:false")
err5="$(_cycle_apply_feedback 6 "$STATE_DIR" 2>&1 >/dev/null || true)"
if grep -qF "⚠" <<< "$err5"; then
    assert_fail "[SPEC-5] optional absent → no ⚠ banner on stderr" "banner appeared: $err5"
else
    assert_pass "[SPEC-5] optional absent → no ⚠ banner on stderr"
fi

print_test_results
