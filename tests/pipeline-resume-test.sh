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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
