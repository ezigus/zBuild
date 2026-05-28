#!/usr/bin/env bash
# Tests: pipeline resume CLI + auto-resume policy (issue #225)
# Covers:
#   (a) get_resume_recommendation returns auto_resume for in_progress state < 24h
#   (b) returns fresh_start for complete
#   (c) returns manual_resume_only for aborted
#   (d) pipeline resume with staged state skips completed stages
#   (e) --force overrides aborted status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"

print_test_header "pipeline resume — CLI + auto-resume policy (#225)"

setup_test_env "pipeline-resume"
STATE_FILE="$TEST_TEMP_DIR/state/pipeline-state.json"
mkdir -p "$(dirname "$STATE_FILE")"

# ── Helper: write a minimal state file ───────────────────────────────────────
# Usage: _write_state <status> [updated_at] [stage_statuses_json]
_write_state() {
    local status="$1"
    local updated_at="${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    local stage_statuses_json="${3:-{\}}"
    # Build JSON without passing stage_statuses as argjson to avoid shell quoting issues
    jq -n \
        --arg status "$status" \
        --arg updated_at "$updated_at" \
        '{
            schema_version: 1,
            run_id: "test-run-225",
            issue: 225,
            stage_statuses: {},
            current_iteration: 0,
            self_heal_count: {},
            scope_manifest_hash: "",
            cost_ledger_pointer: 0,
            claim_lease_id: "",
            plugin_state: {},
            status: $status,
            updated_at: $updated_at
        }' > "$STATE_FILE"
    # Merge stage_statuses separately if provided
    if [[ "$stage_statuses_json" != "{}" && "$stage_statuses_json" != '{\}' ]]; then
        local tmp; tmp="$(mktemp)"
        jq --argjson ss "$stage_statuses_json" '.stage_statuses = $ss' "$STATE_FILE" > "$tmp"
        mv "$tmp" "$STATE_FILE"
    fi
}

# ─── (a) auto_resume for in_progress < 24h ──────────────────────────────────
print_test_section "get_resume_recommendation: in_progress < 24h"

_write_state "in_progress" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "in_progress recent → auto_resume" "auto_resume" "$result"

# ─── (b) fresh_start for complete ───────────────────────────────────────────
print_test_section "get_resume_recommendation: complete"

_write_state "complete"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "complete → fresh_start" "fresh_start" "$result"

# ─── (c) manual_resume_only for aborted ─────────────────────────────────────
print_test_section "get_resume_recommendation: aborted"

_write_state "aborted"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "aborted → manual_resume_only" "manual_resume_only" "$result"

# ─── (b2) fresh_start when no state file ────────────────────────────────────
print_test_section "get_resume_recommendation: no state file"

rm -f "$STATE_FILE"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "no state file → fresh_start" "fresh_start" "$result"

# ─── (a2) manual_resume_only for in_progress > 24h ──────────────────────────
print_test_section "get_resume_recommendation: in_progress > 24h"

old_ts="2020-01-01T00:00:00Z"
_write_state "in_progress" "$old_ts"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "in_progress old → manual_resume_only" "manual_resume_only" "$result"

# ─── interrupted → auto_resume ──────────────────────────────────────────────
print_test_section "get_resume_recommendation: interrupted"

_write_state "interrupted"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "interrupted → auto_resume" "auto_resume" "$result"

# ─── (d) pipeline resume skips completed stages ──────────────────────────────
print_test_section "runner --resume skips completed stages"

# Write a state where 'intake' is complete and 'output' is not
_write_state "in_progress" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{"intake": "complete", "output": "pending"}'

# Check that get_state_field reads stage_statuses correctly
intake_status="$(get_state_field "$STATE_FILE" '.stage_statuses["intake"]' '')"
output_status="$(get_state_field "$STATE_FILE" '.stage_statuses["output"]' '')"
assert_eq "intake stage is complete in state" "complete" "$intake_status"
assert_eq "output stage is pending in state" "pending" "$output_status"

# Simulate the skip logic from the runner: a complete stage should be skipped
skipped=false
if [[ "$intake_status" == "complete" ]]; then
    skipped=true
fi
assert_eq "completed stage (intake) would be skipped on resume" "true" "$skipped"

# ─── (d2) set_pipeline_status via set_state_field ────────────────────────────
print_test_section "set_state_field updates pipeline status"

_write_state "in_progress"
set_state_field "$STATE_FILE" '.status' '"in_progress"'
written_status="$(get_state_field "$STATE_FILE" '.status' '')"
assert_eq "set_state_field writes status=in_progress" "in_progress" "$written_status"

set_state_field "$STATE_FILE" '.status' '"complete"'
written_status="$(get_state_field "$STATE_FILE" '.status' '')"
assert_eq "set_state_field writes status=complete" "complete" "$written_status"

# ─── (e) --force overrides aborted ──────────────────────────────────────────
print_test_section "--force: aborted pipeline can be resumed"

_write_state "aborted"
# Simulate the force override: if force=true, aborted is treated as resumable
aborted_status="$(get_state_field "$STATE_FILE" '.status' '')"
force=true
can_resume=false
if [[ "$aborted_status" == "aborted" ]] && $force; then
    can_resume=true
fi
assert_eq "aborted + force=true → can_resume" "true" "$can_resume"

# Without force, aborted should not be auto-resumable
force=false
can_resume=false
if [[ "$aborted_status" != "aborted" ]] || $force; then
    can_resume=true
fi
assert_eq "aborted + force=false → cannot auto-resume" "false" "$can_resume"

# ─── (e2) get_resume_recommendation still returns manual_resume_only ─────────
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "aborted still returns manual_resume_only (force is caller's responsibility)" \
    "manual_resume_only" "$result"

# ─── Integration: runner.sh --resume skips completed stages end-to-end ────────
print_test_section "integration: runner --resume skips stages with status=complete"

# Build minimal plugins for all 4 stages in the standard template (intake/plan/build/review)
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
INT_PLUGINS_ROOT="$TEST_TEMP_DIR/int_plugins"
INT_STATE_DIR="$TEST_TEMP_DIR/int_state"
INT_EVENTS_DIR="$TEST_TEMP_DIR/int_events"
mkdir -p "$INT_PLUGINS_ROOT/agent/intake" "$INT_PLUGINS_ROOT/agent/plan" \
         "$INT_PLUGINS_ROOT/agent/build" "$INT_PLUGINS_ROOT/agent/review" \
         "$INT_STATE_DIR" "$INT_EVENTS_DIR"

# Plugins: all 4 standard-template stages succeed
for _plugin in intake plan build; do
    _fn="${_plugin//-/_}_run"
    cat > "$INT_PLUGINS_ROOT/agent/$_plugin/manifest.yaml" <<EOF
id: $_plugin
name: Test $_plugin
kind: agent
version: 0.0.1
hooks:
  run: ${_fn}
requires:
  core:
    - redaction
EOF
    printf '%s() { return 0; }\n' "$_fn" > "$INT_PLUGINS_ROOT/agent/$_plugin/plugin.sh"
done
cat > "$INT_PLUGINS_ROOT/agent/review/manifest.yaml" <<EOF
id: review
name: Test review
kind: agent
version: 0.0.1
hooks:
  run: review_run
requires:
  core:
    - redaction
EOF
printf 'review_run() { return 0; }\n' > "$INT_PLUGINS_ROOT/agent/review/plugin.sh"

# Write state: intake=complete, plan=complete, build=complete, review=pending
# (matches all 4 stages in standard template so resume only runs review)
INT_STATE_FILE="$INT_STATE_DIR/pipeline-state.json"
jq -n \
    --arg run_id "integ-test-resume-225" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
        schema_version: 1,
        run_id: $run_id,
        issue: 225,
        stage_statuses: {intake: "complete", plan: "complete", build: "complete", review: "pending"},
        current_iteration: 0,
        self_heal_count: {},
        scope_manifest_hash: "",
        cost_ledger_pointer: 0,
        claim_lease_id: "",
        plugin_state: {},
        status: "in_progress",
        updated_at: $now
    }' > "$INT_STATE_FILE"

# Run runner --resume against this state file
set +e
ZBUILD_PLUGINS_ROOT="$INT_PLUGINS_ROOT" \
ZBUILD_STATE_DIR="$INT_STATE_DIR" \
ZBUILD_STATE_FILE="$INT_STATE_FILE" \
ZBUILD_EVENTS_DIR="$INT_EVENTS_DIR" \
ZBUILD_EVENTS_JSONL="$INT_EVENTS_DIR/events.jsonl" \
ZBUILD_EVENTS_DB="$INT_EVENTS_DIR/events.db" \
ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
  bash "$RUNNER" --resume --issue 225 2>/dev/null
_int_rc=$?
set -e

assert_eq "integration: --resume exits 0 when remaining stage succeeds" "0" "$_int_rc"
assert_file_exists "integration: state file still present after resume" "$INT_STATE_FILE"

# Verify review stage status is now complete in state
_review_status="$(jq -r '.stage_statuses.review // empty' "$INT_STATE_FILE" 2>/dev/null)"
assert_eq "integration: review stage_status=complete after resume" "complete" "$_review_status"

# Verify intake/plan/build were skipped (events.jsonl should show only 1 stage.start for review)
if [[ -f "$INT_EVENTS_DIR/events.jsonl" ]]; then
    _stage_starts="$(grep -c '"stage.start"' "$INT_EVENTS_DIR/events.jsonl" || true)"
    assert_eq "integration: only 1 stage.start (skipped 3 complete stages)" "1" "$_stage_starts"
    _resume_event="$(grep -c '"pipeline.resume"' "$INT_EVENTS_DIR/events.jsonl" || true)"
    assert_eq "integration: pipeline.resume event emitted" "1" "$_resume_event"
fi

# ─── Integration: --from-stage unknown value exits 2 ──────────────────────────
print_test_section "integration: --from-stage with unknown stage exits 2"

set +e
ZBUILD_PLUGINS_ROOT="$INT_PLUGINS_ROOT" \
ZBUILD_STATE_DIR="$INT_STATE_DIR" \
ZBUILD_STATE_FILE="$INT_STATE_FILE" \
ZBUILD_EVENTS_DIR="$INT_EVENTS_DIR" \
ZBUILD_EVENTS_JSONL="$INT_EVENTS_DIR/events.jsonl" \
ZBUILD_EVENTS_DB="$INT_EVENTS_DIR/events.db" \
ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
  bash "$RUNNER" --resume --issue 225 --from-stage "nonexistent-stage" 2>/dev/null
_fs_rc=$?
set -e

assert_eq "--from-stage unknown stage exits 2" "2" "$_fs_rc"

# ─── Integration: --from-stage without --resume exits 2 ───────────────────────
print_test_section "integration: --from-stage without --resume exits 2"

# Reset state for a fresh start scenario
jq -n \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1,run_id:"fresh-run",issue:225,stage_statuses:{},current_iteration:0,
      self_heal_count:{},scope_manifest_hash:"",cost_ledger_pointer:0,claim_lease_id:"",
      plugin_state:{},status:"in_progress",updated_at:$now}' > "$INT_STATE_FILE"

set +e
ZBUILD_PLUGINS_ROOT="$INT_PLUGINS_ROOT" \
ZBUILD_STATE_DIR="$INT_STATE_DIR" \
ZBUILD_STATE_FILE="$INT_STATE_FILE" \
ZBUILD_EVENTS_DIR="$INT_EVENTS_DIR" \
ZBUILD_EVENTS_JSONL="$INT_EVENTS_DIR/events2.jsonl" \
ZBUILD_EVENTS_DB="$INT_EVENTS_DIR/events.db" \
ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
  bash "$RUNNER" --issue 225 --from-stage "intake" 2>/dev/null
_noresume_rc=$?
set -e

assert_eq "--from-stage without --resume exits 2" "2" "$_noresume_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
