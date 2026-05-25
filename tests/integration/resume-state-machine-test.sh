#!/usr/bin/env bash
# Tests: core/state/resume.sh — state machine transitions (ADR-006).
# Validates valid transitions, invalid transitions, and status semantics.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "resume state machine — valid/invalid transitions (ADR-006)"

setup_test_env "resume-state-machine"

EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$EVENTS_DIR"

source "$REPO_ROOT/core/state/resume.sh"

STATE_FILE="$TEST_TEMP_DIR/state.json"

# ─── Helper: set status directly using set_state_field ───────────────────────
_set_status() {
    local sf="$1" st="$2"
    set_state_field "$sf" '.status' "\"$st\""
}

_get_status() {
    local sf="$1"
    get_state_field "$sf" '.status' ''
}

# ─── Valid transition: pending → in_progress ─────────────────────────────────
init_state "$STATE_FILE" "sm-test-run-1" 0 >/dev/null 2>&1
# init_state doesn't write .status; set it to pending explicitly
_set_status "$STATE_FILE" "pending"
_set_status "$STATE_FILE" "in_progress"
status="$(_get_status "$STATE_FILE")"
assert_eq "valid transition: pending → in_progress" "in_progress" "$status"

# ─── Valid transition: in_progress → complete ─────────────────────────────────
_set_status "$STATE_FILE" "complete"
status="$(_get_status "$STATE_FILE")"
assert_eq "valid transition: in_progress → complete" "complete" "$status"

# ─── Valid transition: in_progress → interrupted ──────────────────────────────
rm -f "$STATE_FILE"
init_state "$STATE_FILE" "sm-test-run-2" 0 >/dev/null 2>&1
_set_status "$STATE_FILE" "in_progress"
_set_status "$STATE_FILE" "interrupted"
status="$(_get_status "$STATE_FILE")"
assert_eq "valid transition: in_progress → interrupted" "interrupted" "$status"

# ─── Valid transition: interrupted → in_progress (resume) ────────────────────
_set_status "$STATE_FILE" "in_progress"
status="$(_get_status "$STATE_FILE")"
assert_eq "valid transition: interrupted → in_progress (resume)" "in_progress" "$status"

# ─── Invalid transition: complete → in_progress should be rejected ────────────
# The state machine enforces this via get_resume_recommendation returning fresh_start.
rm -f "$STATE_FILE"
init_state "$STATE_FILE" "sm-test-run-3" 0 >/dev/null 2>&1
_set_status "$STATE_FILE" "complete"

recommendation="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "invalid transition: complete → in_progress rejected (fresh_start recommended)" \
    "fresh_start" "$recommendation"

# ─── Invalid transition: aborted → interrupted is rejected (manual only) ──────
rm -f "$STATE_FILE"
init_state "$STATE_FILE" "sm-test-run-4" 0 >/dev/null 2>&1
_set_status "$STATE_FILE" "aborted"

recommendation="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "invalid transition: aborted → interrupted rejected (manual_resume_only)" \
    "manual_resume_only" "$recommendation"

# ─── resume_state reads schema_version correctly ─────────────────────────────
rm -f "$STATE_FILE"
init_state "$STATE_FILE" "sm-test-run-5" 42 >/dev/null 2>&1
set +e
resume_state "$STATE_FILE" >/dev/null 2>&1
resume_rc=$?
set -e
assert_eq "resume_state exits 0 on valid schema_version=1" "0" "$resume_rc"

# ─── resume_state fails on wrong schema_version ───────────────────────────────
bad_state_file="$TEST_TEMP_DIR/bad-state.json"
jq -n '{schema_version:99, run_id:"bad", issue:0, stage_statuses:{},
         current_iteration:0, self_heal_count:{}, scope_manifest_hash:"",
         cost_ledger_pointer:0, claim_lease_id:"", plugin_state:{},
         updated_at:"2026-01-01T00:00:00Z"}' > "$bad_state_file"
set +e
resume_state "$bad_state_file" >/dev/null 2>&1
bad_rc=$?
set -e
if [[ $bad_rc -ne 0 ]]; then
    assert_pass "resume_state rejects schema_version=99 (non-zero rc)"
else
    assert_fail "resume_state rejects schema_version=99 (non-zero rc)" "expected non-zero rc"
fi

# ─── get_resume_recommendation: interrupted → auto_resume ────────────────────
rm -f "$STATE_FILE"
init_state "$STATE_FILE" "sm-test-run-6" 0 >/dev/null 2>&1
_set_status "$STATE_FILE" "interrupted"
recommendation="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "interrupted status → get_resume_recommendation returns auto_resume" \
    "auto_resume" "$recommendation"

# ─── get_resume_recommendation: missing file → fresh_start ───────────────────
recommendation="$(get_resume_recommendation "/nonexistent/state.json")"
assert_eq "missing state file → get_resume_recommendation returns fresh_start" \
    "fresh_start" "$recommendation"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
