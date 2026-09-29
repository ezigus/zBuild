#!/usr/bin/env bash
# Tests: intake refuse-on-closed propagates rc=1 across a bash subprocess
# boundary (issue #456). Lesson from #449 — assert artifacts AND event are
# emitted from a subprocess, not just the in-process call.
# #1837: also covers SPEC-1 (rc=1 on refuse), SPEC-2 (result file written
# on refusal), and SPEC-16 (SIGTERM mid-run writes fail/broken result).
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

# Artifact dir for SPEC-2 result file checks
ARTIFACT_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"

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
    ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR" \
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

assert_eq "[#1837/SPEC-1] subprocess: refuse propagates rc=1" "1" "$subprocess_rc"
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

# ─── SPEC-2 [change]: intake-result.json written on the refusal path ─────────
assert_file_exists "[#1837/SPEC-2] intake-result.json written on refusal" \
    "$ARTIFACT_DIR/intake-result.json"

# ─── SPEC-16 [change]: SIGTERM mid-run writes verdict=fail, disposition=broken ─
# Run intake in a subprocess with stage_summary_write mocked to sleep long
# enough for SIGTERM to arrive; the v2 SIGTERM trap must write the result file
# before the process exits. stage_summary_write is a direct (non-substituted)
# call that runs after all work is done, making the timing reliable.
_s16_art_dir="$TEST_TEMP_DIR/sigterm-test"
_s16_state_dir="$TEST_TEMP_DIR/sigterm-state"
mkdir -p "$_s16_art_dir" "$_s16_state_dir"
_s16_state_file="$_s16_state_dir/pipeline-state.json"
echo '{"schema_version":1,"run_id":"sigterm","issue":"0","stage_statuses":{}}' \
    > "$_s16_state_file"

set +e
bash -c "
    set -uo pipefail
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/plugins/agent/intake/plugin.sh'
    stage_summary_write() { sleep 10; }
    export ZBUILD_GOAL='sigterm test: verifying v2 signal handling'
    export ZBUILD_ARTIFACT_DIR='$_s16_art_dir'
    export ZBUILD_INTAKE_SKIP_BRANCH=1
    export ZBUILD_EVENTS_DIR='$ZBUILD_EVENTS_DIR'
    export ZBUILD_EVENTS_JSONL='$ZBUILD_EVENTS_JSONL'
    export ZBUILD_EVENTS_DB='$ZBUILD_EVENTS_DB'
    export ZBUILD_EVENT_SCHEMA='$ZBUILD_EVENT_SCHEMA'
    intake_run 'intake' '$_s16_state_file' &
    _subpid=\$!
    sleep 0.3
    kill -TERM \"\$_subpid\" 2>/dev/null || true
    wait \"\$_subpid\" 2>/dev/null || true
" 2>/dev/null
set -e

assert_file_exists "[#1837/SPEC-16] SIGTERM: intake-result.json written before exit" \
    "$_s16_art_dir/intake-result.json"
if [[ -f "$_s16_art_dir/intake-result.json" ]]; then
    _s16_verdict="$(jq -r '.verdict // empty' "$_s16_art_dir/intake-result.json" 2>/dev/null || true)"
    _s16_disp="$(jq -r '.disposition // empty' "$_s16_art_dir/intake-result.json" 2>/dev/null || true)"
    assert_eq "[#1837/SPEC-16] SIGTERM: verdict=fail" "fail" "$_s16_verdict"
    assert_eq "[#1837/SPEC-16] SIGTERM: disposition=broken" "broken" "$_s16_disp"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
