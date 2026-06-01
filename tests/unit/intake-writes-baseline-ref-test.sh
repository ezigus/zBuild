#!/usr/bin/env bash
# Tests: plugins/agent/intake — writes intake-baseline-ref.txt (#614)
#
# Asserts the intake stage, after creating/reusing the workspace branch,
# records the post-checkout HEAD SHA to ${state_dir}/intake-baseline-ref.txt
# and emits an intake.baseline.captured event for observability.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "intake: writes intake-baseline-ref.txt (#614)"
setup_test_env "intake-614-baseline"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../plugins/agent/intake/plugin.sh
source "$REPO_ROOT/plugins/agent/intake/plugin.sh"

REPO="$(setup_git_temp_repo zbuild-614-repo)"
if [[ -z "$REPO" || ! -d "$REPO/.git" ]]; then
    assert_fail "setup_git_temp_repo created a usable repo" "no .git at $REPO"
    cleanup_test_env; print_test_results; exit 1
fi

STATE_DIR="$TEST_TEMP_DIR/state-614"
mkdir -p "$STATE_DIR"

cd "$REPO" || exit 1

# Drive the same orchestrator the real intake_run path calls.
: > "$ZBUILD_EVENTS_JSONL"
_intake_create_workspace_branch "$STATE_DIR" 614 "branch cumulative context" \
    > /tmp/intake-614-out.$$ 2>&1
rc=$?
assert_eq "branch creation rc=0" "0" "$rc"

# Post-checkout HEAD (what intake should record)
expected_sha="$(git -C "$REPO" rev-parse HEAD)"

# RED expectation: the file must exist and equal the post-checkout HEAD SHA.
assert_file_exists "intake-baseline-ref.txt exists" \
    "$STATE_DIR/intake-baseline-ref.txt"
got_sha="$(cat "$STATE_DIR/intake-baseline-ref.txt" 2>/dev/null || echo MISSING)"
assert_eq "baseline ref equals post-checkout HEAD" "$expected_sha" "$got_sha"

# No trailing newline — pure 40-char hex.
byte_count=$(wc -c < "$STATE_DIR/intake-baseline-ref.txt" | tr -d ' ')
assert_eq "baseline file is 40 bytes (no trailing newline)" "40" "$byte_count"

# Event emitted
baseline_count=$(grep -c '"intake.baseline.captured"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)
# grep -c can output blank when missing; normalize
baseline_count="${baseline_count:-0}"
assert_gt "intake.baseline.captured emitted" "$baseline_count" "0"

cd "$REPO_ROOT" || true
rm -f /tmp/intake-614-out.$$
cleanup_test_env
print_test_results
exit $((FAIL > 0))
