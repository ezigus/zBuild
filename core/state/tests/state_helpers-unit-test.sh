#!/usr/bin/env bash
# Tests: core/pipeline/state_helpers.sh — _update_stage_status, _set_pipeline_status,
#        write_scope_override; issue #368.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# state_helpers.sh self-sources atomic.sh; source in correct order.
source "$REPO_ROOT/core/state/resume.sh"
source "$REPO_ROOT/core/pipeline/state_helpers.sh"

print_test_header "core/pipeline/state_helpers — _update_stage_status, _set_pipeline_status (#368)"

setup_test_env "core-state-helpers"
STATE_FILE="$TEST_TEMP_DIR/state/pipeline-state.json"
mkdir -p "$(dirname "$STATE_FILE")"

# Bootstrap a valid state file via init_state
init_state "$STATE_FILE" "run-helpers-test" 55 >/dev/null

# ─── Section 1: _update_stage_status ─────────────────────────────────────────
print_test_section "Section 1: _update_stage_status"

_update_stage_status "$STATE_FILE" "intake" "complete" >/dev/null
val="$(jq -r '.stage_statuses.intake' "$STATE_FILE")"
assert_eq "intake stage set to complete" "complete" "$val"

_update_stage_status "$STATE_FILE" "build" "in_progress" >/dev/null
val="$(jq -r '.stage_statuses.build' "$STATE_FILE")"
assert_eq "build stage set to in_progress" "in_progress" "$val"

_update_stage_status "$STATE_FILE" "intake" "failed" >/dev/null
val="$(jq -r '.stage_statuses.intake' "$STATE_FILE")"
assert_eq "intake stage updated to failed" "failed" "$val"

# Verify updated_at is bumped
updated_at="$(jq -r '.updated_at' "$STATE_FILE")"
assert_contains_regex "updated_at looks like ISO-8601" "$updated_at" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T"

# ─── Section 2: _update_stage_status does not clobber other stages ───────────
print_test_section "Section 2: _update_stage_status preserves other stage statuses"

_update_stage_status "$STATE_FILE" "review" "complete" >/dev/null
# build should still be in_progress from above
val_build="$(jq -r '.stage_statuses.build' "$STATE_FILE")"
val_review="$(jq -r '.stage_statuses.review' "$STATE_FILE")"
assert_eq "build status preserved after review update" "in_progress" "$val_build"
assert_eq "review status set correctly" "complete" "$val_review"

# ─── Section 3: _set_pipeline_status ─────────────────────────────────────────
print_test_section "Section 3: _set_pipeline_status"

_set_pipeline_status "$STATE_FILE" "in_progress" >/dev/null
val="$(jq -r '.status' "$STATE_FILE")"
assert_eq "pipeline status set to in_progress" "in_progress" "$val"

_set_pipeline_status "$STATE_FILE" "complete" >/dev/null
val="$(jq -r '.status' "$STATE_FILE")"
assert_eq "pipeline status updated to complete" "complete" "$val"

_set_pipeline_status "$STATE_FILE" "interrupted" >/dev/null
val="$(jq -r '.status' "$STATE_FILE")"
assert_eq "pipeline status updated to interrupted" "interrupted" "$val"

# ─── Section 4: _set_pipeline_status does not clobber stage_statuses ─────────
print_test_section "Section 4: _set_pipeline_status does not clobber stage_statuses"

_set_pipeline_status "$STATE_FILE" "aborted" >/dev/null
val_build="$(jq -r '.stage_statuses.build' "$STATE_FILE")"
val_review="$(jq -r '.stage_statuses.review' "$STATE_FILE")"
assert_eq "build stage preserved after pipeline status change" "in_progress" "$val_build"
assert_eq "review stage preserved after pipeline status change" "complete" "$val_review"

# ─── Section 5: get_state_field reads fields correctly ───────────────────────
print_test_section "Section 5: get_state_field round-trip"

val="$(get_state_field "$STATE_FILE" '.issue' '0')"
assert_eq "get_state_field .issue returns 55" "55" "$val"

val="$(get_state_field "$STATE_FILE" '.run_id' '')"
assert_eq "get_state_field .run_id returns run-helpers-test" "run-helpers-test" "$val"

val="$(get_state_field "$STATE_FILE" '.nonexistent' 'fallback')"
assert_eq "get_state_field returns default for missing key" "fallback" "$val"

# Missing file returns default without error
val="$(get_state_field "/tmp/no-such-file-zbuild-test.json" '.anything' 'mydefault')"
assert_eq "get_state_field on missing file returns default" "mydefault" "$val"

# ─── Section 6: set_state_field ──────────────────────────────────────────────
print_test_section "Section 6: set_state_field"

set_state_field "$STATE_FILE" '.current_iteration' "7" >/dev/null
val="$(get_state_field "$STATE_FILE" '.current_iteration' '0')"
assert_eq "set_state_field sets current_iteration to 7" "7" "$val"

set_state_field "$STATE_FILE" '.scope_manifest_hash' '"abc123"' >/dev/null
val="$(get_state_field "$STATE_FILE" '.scope_manifest_hash' '')"
assert_eq "set_state_field sets scope_manifest_hash string" "abc123" "$val"

# ─── Section 7: write_scope_override ─────────────────────────────────────────
print_test_section "Section 7: write_scope_override"

STATE_DIR="$TEST_TEMP_DIR/state"
unset ZBUILD_SCOPE_PATHS

# No ZBUILD_SCOPE_PATHS → function is a no-op, file not created
write_scope_override "$STATE_DIR" "run-xyz" >/dev/null 2>&1 || true
assert_file_not_exists "write_scope_override no-ops when ZBUILD_SCOPE_PATHS unset" \
    "$STATE_DIR/scope-override.md"

# With ZBUILD_SCOPE_PATHS set
export ZBUILD_SCOPE_PATHS="src/core
plugins/agent"
write_scope_override "$STATE_DIR" "run-xyz" >/dev/null
assert_file_exists "write_scope_override creates scope-override.md" \
    "$STATE_DIR/scope-override.md"

scope_content="$(cat "$STATE_DIR/scope-override.md")"
assert_contains "scope-override.md contains first path in '+ <path>' format" \
    "$scope_content" "+ src/core"
assert_contains "scope-override.md contains second path in '+ <path>' format" \
    "$scope_content" "+ plugins/agent"
assert_contains "scope-override.md contains run_id" \
    "$scope_content" "run-xyz"

unset ZBUILD_SCOPE_PATHS

# ─── Section 8: get_state_field corruption recovery ──────────────────────────
print_test_section "Section 8: get_state_field corruption recovery [SPEC-1..3]"

CORRUPT_DIR="$TEST_TEMP_DIR/state-corrupt"
mkdir -p "$CORRUPT_DIR"
CORRUPT_STATE="$CORRUPT_DIR/pipeline-state.json"

# Seed a valid state so we have a known field value to recover.
init_state "$CORRUPT_STATE" "run-corrupt-test" 99 >/dev/null

# Stash a valid .bak copy, then corrupt the main file.
cp "$CORRUPT_STATE" "${CORRUPT_STATE}.bak"
echo "NOT_JSON{{{" > "$CORRUPT_STATE"

# [SPEC-1] Corrupt main + valid .bak → recover and return correct field.
val="$(get_state_field "$CORRUPT_STATE" '.issue' '0')"
assert_eq "[SPEC-1] get_state_field recovers from .bak when main is corrupt" "99" "$val"

# Corrupt both files (main was already restored by the previous call; corrupt again).
echo "NOT_JSON{{{" > "$CORRUPT_STATE"
echo "ALSO_BAD" > "${CORRUPT_STATE}.bak"

# [SPEC-2] Both corrupt → return default, exit 0 (no crash).
val="$(get_state_field "$CORRUPT_STATE" '.issue' 'fallback99')"
assert_eq "[SPEC-2] get_state_field returns default when both main and .bak are corrupt" "fallback99" "$val"

# [SPEC-3] Valid file (no corruption) still returns correct field after wiring.
CLEAN_DIR="$TEST_TEMP_DIR/state-clean"
mkdir -p "$CLEAN_DIR"
CLEAN_STATE="$CLEAN_DIR/pipeline-state.json"
init_state "$CLEAN_STATE" "run-clean-test" 77 >/dev/null
val="$(get_state_field "$CLEAN_STATE" '.issue' '0')"
assert_eq "[SPEC-3] get_state_field returns correct field for valid state file" "77" "$val"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
