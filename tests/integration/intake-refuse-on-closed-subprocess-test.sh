#!/usr/bin/env bash
# Tests: intake refuse-on-closed propagates rc=1 across a bash subprocess
# boundary (issue #456). Lesson from #449 — assert artifacts AND event are
# emitted from a subprocess, not just the in-process call.
# #1837: also covers SPEC-1 (rc=1 on refuse), SPEC-2 (result file written
# on refusal), and SPEC-16 (SIGTERM mid-run writes a fail result). The close-out
# fixed the words: a closed issue is misconfigured (the operator chose it; nothing
# was down) and a signal is interrupted (retry), never broken (halt).
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
assert_eq "[#1837] a closed issue is misconfigured — nothing was down" "misconfigured" \
    "$(jq -r '.disposition // empty' "$ARTIFACT_DIR/intake-result.json" 2>/dev/null || true)"

# ─── SPEC-16 [change] / SPEC-2 [change]: SIGTERM mid-run ────────────────────
# The workspace-branch step — mid-stage, before any result exists — is stubbed
# to announce itself and then wait on a child:
# `wait` returns as soon as a trapped signal arrives, where a foreground `sleep`
# would hold the trap until it finished (the old stub slept 10s every run). The
# parent kills only once the stub has announced — no fixed delay to race.
# Temporal ordering is structural: the artifact dir is empty before the
# subprocess starts and only the subprocess writes to it.
_s16_art_dir="$TEST_TEMP_DIR/sigterm-test"
_s16_state_dir="$TEST_TEMP_DIR/sigterm-state"
mkdir -p "$_s16_art_dir" "$_s16_state_dir"
_s16_state_file="$_s16_state_dir/pipeline-state.json"
_s16_ready="$TEST_TEMP_DIR/sigterm-ready"
echo '{"schema_version":1,"run_id":"sigterm","issue":"0","stage_statuses":{}}' \
    > "$_s16_state_file"

if [[ -f "$_s16_art_dir/intake-result.json" ]]; then
    assert_fail "[#1837/SPEC-16] artifact dir must be empty before SIGTERM test starts" \
        "pre-existing file found"
fi

set +e
bash -c "
    set -uo pipefail
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/plugins/agent/intake/plugin.sh'
    _intake_create_workspace_branch() { sleep 30 >/dev/null 2>&1 & printf '%s' \$! > '$_s16_ready'; wait \$!; }
    export ZBUILD_GOAL='sigterm test: verifying v2 signal handling'
    export ZBUILD_ARTIFACT_DIR='$_s16_art_dir'
    export ZBUILD_INTAKE_SKIP_BRANCH=0
    export ZBUILD_EVENTS_DIR='$ZBUILD_EVENTS_DIR'
    export ZBUILD_EVENTS_JSONL='$ZBUILD_EVENTS_JSONL'
    export ZBUILD_EVENTS_DB='$ZBUILD_EVENTS_DB'
    export ZBUILD_EVENT_SCHEMA='$ZBUILD_EVENT_SCHEMA'
    intake_run 'intake' '$_s16_state_file' &
    _subpid=\$!
    for _i in \$(seq 1 200); do [[ -s '$_s16_ready' ]] && break; sleep 0.05; done
    kill -TERM \"\$_subpid\" 2>/dev/null || true
    wait \"\$_subpid\" 2>/dev/null || true
    # The stub's sleep outlives the killed stage (it is reparented, so -P
    # would find nothing): kill it by the pid the stub recorded (review).
    kill \"\$(cat '$_s16_ready')\" 2>/dev/null || true
" 2>/dev/null
set -e

assert_file_exists "[#1837/SPEC-16] fixture: the stub was reached before the signal" "$_s16_ready"
assert_file_exists "[#1837/SPEC-2][#1837/SPEC-16] SIGTERM: intake-result.json written before exit" \
    "$_s16_art_dir/intake-result.json"
if [[ -f "$_s16_art_dir/intake-result.json" ]]; then
    assert_eq "[#1837/SPEC-16] SIGTERM: verdict=fail" "fail" \
        "$(jq -r '.verdict // empty' "$_s16_art_dir/intake-result.json" 2>/dev/null || true)"
    assert_eq "[#1837/SPEC-16] SIGTERM: disposition=interrupted (retry), not broken (halt)" "interrupted" \
        "$(jq -r '.disposition // empty' "$_s16_art_dir/intake-result.json" 2>/dev/null || true)"
    assert_eq "[#1837/SPEC-16] SIGTERM: reason=signal_interrupt" "signal_interrupt" \
        "$(jq -r '.reason // empty' "$_s16_art_dir/intake-result.json" 2>/dev/null || true)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
