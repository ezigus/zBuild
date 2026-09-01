#!/usr/bin/env bash
# Tests: intake refuse-on-closed propagates rc=2 across a bash subprocess
# boundary (issue #456). Lesson from #449 — assert artifacts AND event are
# emitted from a subprocess, not just the in-process call.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "intake refuse-on-closed — subprocess boundary (#456)"
setup_test_env "intake-refuse-subprocess"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
# These were real issue numbers used as run identity.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR"
echo '{"schema_version":1,"run_id":"t","issue":"$_ZB_ID","stage_statuses":{}}' > "$STATE_FILE"

# Mock `gh` via PATH shim — CLOSED/COMPLETED for state, repo slug for URL.
mock_binary "gh" '
case "${1:-} ${2:-}" in
    "issue view")
        if [[ "${4:-}" == "--json" && "${5:-}" == "state,stateReason" ]]; then
            payload="{\"state\":\"CLOSED\",\"stateReason\":\"COMPLETED\"}"
            if [[ "${6:-}" == "--jq" ]]; then
                printf "%s" "$payload" | jq -r "$7"
            else
                printf "%s" "$payload"
            fi
            exit 0
        fi
        # title+body shape — should NOT be invoked on refuse path
        printf "mock gh: title/body should not be fetched after refusal\n" >&2
        exit 99
        ;;
    "repo view")
        printf "%s\n" "acme/zbuild"
        exit 0
        ;;
    *)
        printf "mock gh: unexpected: %s\n" "$*" >&2
        exit 2
        ;;
esac
'

# Run intake_run from a forked bash subprocess.
set +e
subprocess_err="$(
    ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL" \
    ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DB" \
    ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA" \
    ZBUILD_ISSUE="$_ZB_ID" \
    PATH="$TEST_TEMP_DIR/bin:$PATH" \
    bash -c "
        set -euo pipefail
        source '$REPO_ROOT/scripts/lib/helpers.sh'
        source '$REPO_ROOT/plugins/agent/intake/plugin.sh'
        unset ZBUILD_GOAL
        intake_run 'intake' '$STATE_FILE'
    " 2>&1 >/dev/null
)"
subprocess_rc=$?
set -e

assert_eq "subprocess: refuse propagates rc=2" "2" "$subprocess_rc"
assert_contains "subprocess: stderr mentions CLOSED" "$subprocess_err" "CLOSED"
assert_contains "subprocess: stderr mentions the issue" "$subprocess_err" "#$_ZB_ID"

# No intake.md should have been written
if [[ -e "$STATE_DIR/intake.md" ]]; then
    assert_fail "subprocess: intake.md must not be written on refusal"
else
    assert_pass "subprocess: intake.md not written on refusal"
fi

refused_count=$(grep -c '"intake.refused.issue_closed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_gt "subprocess: intake.refused.issue_closed event in jsonl" "$refused_count" "0"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
