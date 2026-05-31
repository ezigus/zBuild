#!/usr/bin/env bash
# Tests: cycle-orchestrator _cycle_detect_blocked predicate (#528, ADR-021 amendment)
#
# Blocked fires when ANY stage in _CYCLE_STAGES[] this iter has raw verdict ∈
# {error, corrupt_diff, block} (the "cannot-recover" class). Does NOT fire on:
#   - verdict=fail (legitimate negative signal — keep iterating)
#   - verdict=missing (handled by cycle.iteration.verdict_missing in
#     _cycle_check_until)
#   - verdict=scope_violation (actionable — review can reject)
# Bypassed when _CYCLE_UNTIL_VALUE == "error" (operator template explicitly
# converging on error).
# Fail-CLOSED on jq parse error / empty blob (treat as terminate-now).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — blocked predicate (#528)"
setup_test_env "cycle-blocked"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

_setup_blocked_ctx() {
    _CYCLE_TRAP_CYCLE_ID="test"
    _CYCLE_TRAP_ITER="${1:-1}"
    _CYCLE_STAGES=(build test)
    _CYCLE_UNTIL_VALUE="${2:-pass}"
}

# U1: verdict=error iter 1 → blocked (rc 0)
: > "$ZBUILD_EVENTS_JSONL"
_setup_blocked_ctx 1 pass
blob='{"build":{"verdict":"pass","status":"complete"},"test":{"verdict":"error","status":"failed"}}'
set +e; _cycle_detect_blocked "$blob" 1; rc=$?; set -e
assert_eq "U1: verdict=error → blocked (rc=0)" "0" "$rc"

# U2: verdict=fail iter 1 → NOT blocked (rc 1)
_setup_blocked_ctx 1 pass
blob='{"build":{"verdict":"pass","status":"complete"},"test":{"verdict":"fail","status":"failed"}}'
set +e; _cycle_detect_blocked "$blob" 1; rc=$?; set -e
assert_eq "U2: verdict=fail → NOT blocked (rc=1)" "1" "$rc"

# U3: verdict=pass → NOT blocked
_setup_blocked_ctx 1 pass
blob='{"build":{"verdict":"pass","status":"complete"},"test":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_detect_blocked "$blob" 1; rc=$?; set -e
assert_eq "U3: verdict=pass → NOT blocked (rc=1)" "1" "$rc"

# U4: verdict=corrupt_diff → blocked
_setup_blocked_ctx 1 pass
blob='{"build":{"verdict":"corrupt_diff","status":"failed"},"test":{"verdict":"missing","status":"missing"}}'
set +e; _cycle_detect_blocked "$blob" 1; rc=$?; set -e
assert_eq "U4: verdict=corrupt_diff → blocked (rc=0)" "0" "$rc"

# U5: verdict=block → blocked
_setup_blocked_ctx 1 pass
blob='{"build":{"verdict":"block","status":"failed"},"test":{"verdict":"missing","status":"missing"}}'
set +e; _cycle_detect_blocked "$blob" 1; rc=$?; set -e
assert_eq "U5: verdict=block → blocked (rc=0)" "0" "$rc"

# U6: verdict=missing → NOT blocked (handled by verdict_missing event in
# _cycle_check_until, must not double-emit)
_setup_blocked_ctx 1 pass
blob='{"build":{"verdict":"pass","status":"complete"},"test":{"verdict":"missing","status":"missing"}}'
set +e; _cycle_detect_blocked "$blob" 1; rc=$?; set -e
assert_eq "U6: verdict=missing → NOT blocked (rc=1)" "1" "$rc"

# U7: verdict=scope_violation → NOT blocked (actionable — review can reject)
_setup_blocked_ctx 1 pass
blob='{"build":{"verdict":"scope_violation","status":"failed"},"test":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_detect_blocked "$blob" 1; rc=$?; set -e
assert_eq "U7: verdict=scope_violation → NOT blocked (rc=1)" "1" "$rc"

# U8: _CYCLE_UNTIL_VALUE=error → skip blocked detection even if error present
_setup_blocked_ctx 1 error
blob='{"build":{"verdict":"pass","status":"complete"},"test":{"verdict":"error","status":"failed"}}'
set +e; _cycle_detect_blocked "$blob" 1; rc=$?; set -e
assert_eq "U8: until.value=error → skip blocked (rc=1)" "1" "$rc"

# U9: jq parse failure → fail-CLOSED with cycle.metric.invalid event
: > "$ZBUILD_EVENTS_JSONL"
_setup_blocked_ctx 1 pass
set +e; _cycle_detect_blocked "this is not json {" 1; rc=$?; set -e
assert_eq "U9: jq parse failure → fail-CLOSED (rc=0, terminate-now)" "0" "$rc"
assert_event_emitted "U9: cycle.metric.invalid emitted on jq parse failure" \
    "$ZBUILD_EVENTS_JSONL" "cycle.metric.invalid"

# U10: empty blob {} → fail-CLOSED with cycle.metric.invalid event
: > "$ZBUILD_EVENTS_JSONL"
_setup_blocked_ctx 1 pass
set +e; _cycle_detect_blocked '{}' 1; rc=$?; set -e
assert_eq "U10: empty blob → fail-CLOSED (rc=0)" "0" "$rc"
assert_event_emitted "U10: cycle.metric.invalid emitted on empty blob" \
    "$ZBUILD_EVENTS_JSONL" "cycle.metric.invalid"

print_test_results
