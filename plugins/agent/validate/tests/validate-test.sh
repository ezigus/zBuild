#!/usr/bin/env bash
# Tests: plugins/agent/validate — validate stage agent unit tests (issue #757)
#
# Covers: SPEC-8..13 (validate plugin contract)
# SPEC-8:  validate plugin exists with validate_agent_run function
# SPEC-9:  ZBUILD_DRY_RUN=1 writes validate-result.json with verdict=healthy
# SPEC-10: missing deploy-result.json → validate_agent_run rc!=0
# SPEC-11: successful health probe (health_check_run rc=0) → verdict=healthy
# SPEC-12: failed health probe (health_check_run rc!=0) → verdict=error
# SPEC-13: validate plugin has legacy-citation in header comment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: validate agent (kind:agent, ADR-018 P1, issue #757)"

setup_test_env "plugin-validate"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export ZBUILD_RUN_ID="validate-test-$$"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_ISSUE="757"

PLUGIN_FILE="$REPO_ROOT/plugins/agent/validate/plugin.sh"

# Source the validate agent plugin
# shellcheck source=../../../../plugins/agent/validate/plugin.sh
source "$PLUGIN_FILE"

# ─── Mocks ───────────────────────────────────────────────────────────────────

# Override emit_event to no-op so tests don't require a real event-bus backend
emit_event() { return 0; }

# Override apply_scope_redaction as a passthrough
apply_scope_redaction() {
    local _in="$1" _out="$2"
    cp "$_in" "$_out"
    return 0
}

# ─── Helper: make a minimal state file ───────────────────────────────────────
_make_state() {
    local dir="$1"
    mkdir -p "$dir/artifacts"
    printf '{"issue":"757","run_id":"%s"}\n' "$ZBUILD_RUN_ID" > "$dir/state.json"
    printf '%s\n' "$dir/state.json"
}

# ─── Shared: mock health_check_run via load guard ────────────────────────────
# Set the load guard so the real health-check plugin.sh is never sourced.
# We define the mock here; _validate_agent_run_inner will find the type check
# passing because health_check_run is already defined.
_ZBUILD_HEALTH_CHECK_LOADED=1
_MOCK_HC_RC=0
health_check_run() {
    printf 'HTTP/1.1 200 OK\n'
    return "$_MOCK_HC_RC"
}

# ---------------------------------------------------------------------------
# SPEC-8: validate plugin exists with validate_agent_run function
# ---------------------------------------------------------------------------
if [[ -f "$PLUGIN_FILE" ]]; then
    assert_pass "[SPEC-8] validate plugin.sh exists at expected path"
else
    assert_fail "[SPEC-8] validate plugin.sh exists at expected path" \
        "not found: $PLUGIN_FILE"
fi

if type validate_agent_run >/dev/null 2>&1; then
    assert_pass "[SPEC-8] validate_agent_run function defined after source"
else
    assert_fail "[SPEC-8] validate_agent_run function defined after source" \
        "function not found"
fi

# ---------------------------------------------------------------------------
# SPEC-9: ZBUILD_DRY_RUN=1 writes validate-result.json with verdict=healthy
# ---------------------------------------------------------------------------
_run9="$TEST_TEMP_DIR/run9"
_sf9="$(_make_state "$_run9")"
printf '{"schema_version":1,"verdict":"deployed","mode":"dry_run"}\n' \
    > "$_run9/artifacts/deploy-result.json"

ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$_sf9"
_v9="$(jq -r '.verdict' "$_run9/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-9] dry-run writes verdict=healthy" "healthy" "$_v9"
ZBUILD_DRY_RUN=0

# ---------------------------------------------------------------------------
# SPEC-10: missing deploy-result.json → validate_agent_run rc!=0
# ---------------------------------------------------------------------------
_run10="$TEST_TEMP_DIR/run10"
_sf10="$(_make_state "$_run10")"
# Do NOT create deploy-result.json

_rc10=0
_validate_agent_run_inner "$_sf10" || _rc10=$?
assert_gt "[SPEC-10] missing deploy-result.json → rc != 0" "$_rc10" "0"

_v10="$(jq -r '.verdict' "$_run10/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-10] missing deploy-result.json → verdict=error in output" "error" "$_v10"

# ---------------------------------------------------------------------------
# SPEC-11: successful health probe (rc=0) → verdict=healthy in validate-result.json
# ---------------------------------------------------------------------------
_run11="$TEST_TEMP_DIR/run11"
_sf11="$(_make_state "$_run11")"
printf '{"schema_version":1,"verdict":"deployed"}\n' \
    > "$_run11/artifacts/deploy-result.json"

_MOCK_HC_RC=0  # probe succeeds
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf11"
_v11="$(jq -r '.verdict' "$_run11/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-11] healthy probe → verdict=healthy" "healthy" "$_v11"

# ---------------------------------------------------------------------------
# SPEC-12: failed health probe (rc!=0) → verdict=error in validate-result.json
# ---------------------------------------------------------------------------
_run12="$TEST_TEMP_DIR/run12"
_sf12="$(_make_state "$_run12")"
printf '{"schema_version":1,"verdict":"deployed"}\n' \
    > "$_run12/artifacts/deploy-result.json"

_MOCK_HC_RC=1  # probe fails
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf12"
_v12="$(jq -r '.verdict' "$_run12/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-12] failed probe → verdict=error" "error" "$_v12"
_MOCK_HC_RC=0  # reset

# ---------------------------------------------------------------------------
# SPEC-13: validate plugin has legacy-citation in header comment
# ---------------------------------------------------------------------------
if grep -q "legacy-citation" "$PLUGIN_FILE"; then
    assert_pass "[SPEC-13] validate plugin has legacy-citation in header"
else
    assert_fail "[SPEC-13] validate plugin has legacy-citation in header" \
        "legacy-citation not found in $PLUGIN_FILE"
fi

# Verify the specific cited file
if grep -q "pipeline-stages-monitor.sh" "$PLUGIN_FILE"; then
    assert_pass "[SPEC-13] legacy-citation references pipeline-stages-monitor.sh"
else
    assert_fail "[SPEC-13] legacy-citation references pipeline-stages-monitor.sh" \
        "pipeline-stages-monitor.sh not found in legacy-citation"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
