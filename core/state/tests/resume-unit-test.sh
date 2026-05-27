#!/usr/bin/env bash
# Tests: core/state/resume.sh — get_resume_recommendation, should_resume_from_stage
# ADR-006 resume contract; issue #368.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/core/state/resume.sh"

print_test_header "core/state/resume — get_resume_recommendation (#368)"

setup_test_env "core-state-resume"
STATE_FILE="$TEST_TEMP_DIR/state/pipeline-state.json"
mkdir -p "$(dirname "$STATE_FILE")"

# ─── Helper: write a minimal state file ────────────────────────────────────────
_write_state() {
    local status="$1"
    local updated_at="${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    jq -n \
        --arg status "$status" \
        --arg updated_at "$updated_at" \
        '{schema_version:1,run_id:"test-run",issue:42,
          stage_statuses:{},current_iteration:0,self_heal_count:{},
          scope_manifest_hash:"",cost_ledger_pointer:0,
          claim_lease_id:"",plugin_state:{},
          status:$status,updated_at:$updated_at}' > "$STATE_FILE"
}

# ─── Section 1: missing / non-existent state file ────────────────────────────
print_test_section "Section 1: no state file → fresh_start"

rm -f "$STATE_FILE"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "no state file → fresh_start" "fresh_start" "$result"

# ─── Section 2: status=complete → fresh_start ────────────────────────────────
print_test_section "Section 2: status=complete → fresh_start"

_write_state "complete"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "status=complete → fresh_start" "fresh_start" "$result"

# ─── Section 3: status=aborted → manual_resume_only ─────────────────────────
print_test_section "Section 3: status=aborted → manual_resume_only"

_write_state "aborted"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "status=aborted → manual_resume_only" "manual_resume_only" "$result"

# ─── Section 4: status=interrupted → auto_resume ─────────────────────────────
print_test_section "Section 4: status=interrupted → auto_resume"

_write_state "interrupted"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "status=interrupted → auto_resume" "auto_resume" "$result"

# ─── Section 5: status=in_progress, recent timestamp → auto_resume ───────────
print_test_section "Section 5: in_progress + recent → auto_resume"

# 1 hour ago
if date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    recent_ts="$(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ)"
else
    recent_ts="$(TZ=UTC date -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
_write_state "in_progress" "$recent_ts"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "in_progress + 1h ago → auto_resume" "auto_resume" "$result"

# ─── Section 6: status=in_progress, old timestamp → manual_resume_only ──────
print_test_section "Section 6: in_progress + stale → manual_resume_only"

old_ts="2020-01-01T00:00:00Z"
_write_state "in_progress" "$old_ts"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "in_progress + 2020-01-01 → manual_resume_only" "manual_resume_only" "$result"

# ─── Section 7: status=in_progress, empty updated_at → manual_resume_only ───
print_test_section "Section 7: in_progress + empty updated_at → manual_resume_only"

# Overwrite with a state that has an empty updated_at
jq -n '{schema_version:1,run_id:"r",issue:1,stage_statuses:{},
         current_iteration:0,self_heal_count:{},
         scope_manifest_hash:"",cost_ledger_pointer:0,
         claim_lease_id:"",plugin_state:{},
         status:"in_progress",updated_at:""}' > "$STATE_FILE"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "in_progress + empty updated_at → manual_resume_only" "manual_resume_only" "$result"

# ─── Section 8: unknown status → fresh_start ─────────────────────────────────
print_test_section "Section 8: unknown status → fresh_start"

_write_state "unknown_value"
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "unknown status → fresh_start" "fresh_start" "$result"

# ─── Section 9: empty status field → fresh_start ─────────────────────────────
print_test_section "Section 9: empty status field → fresh_start"

_write_state ""
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "empty status → fresh_start" "fresh_start" "$result"

# ─── Section 10: init_state + get_resume_recommendation ──────────────────────
print_test_section "Section 10: freshly init'd state has no .status → fresh_start"

rm -f "$STATE_FILE"
init_state "$STATE_FILE" "run-abc" 99 >/dev/null
result="$(get_resume_recommendation "$STATE_FILE")"
assert_eq "init_state output → fresh_start (no .status set yet)" "fresh_start" "$result"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
