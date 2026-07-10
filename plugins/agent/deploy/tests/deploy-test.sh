#!/usr/bin/env bash
# Tests: plugins/agent/deploy — deploy stage agent unit tests (issue #757)
#
# Covers: SPEC-1..7 (deploy plugin contract)
# SPEC-1: deploy plugin exists with deploy_agent_run function
# SPEC-2: ZBUILD_DRY_RUN=1 writes deploy-result.json with verdict=deployed
# SPEC-3: missing pr-url.txt → deploy_agent_run rc!=0
# SPEC-4: gate-aggregator verdict=fail → verdict=skipped in deploy-result.json
# SPEC-5: deploy plugin has "Role: deploy_agent" preamble comment
# SPEC-6: deploy plugin does NOT contain a route_to_model call (no LLM)
# SPEC-7: dry-run deploy-result.json carries schema_version=1 field
# SPEC-8: gate result MISSING (non-dry-run) → fail-closed rc=2 + verdict=error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: deploy agent (kind:agent, ADR-018 P1, issue #757)"

setup_test_env "plugin-deploy"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export ZBUILD_RUN_ID="deploy-test-$$"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_ISSUE="757"

PLUGIN_FILE="$REPO_ROOT/plugins/agent/deploy/plugin.sh"

# Source the deploy agent plugin
# shellcheck source=../../../../plugins/agent/deploy/plugin.sh
source "$PLUGIN_FILE"

# ─── Mocks ───────────────────────────────────────────────────────────────────

# Override emit_event to no-op so tests don't require a real event-bus backend
emit_event() { return 0; }

# Override apply_scope_redaction as a passthrough (not called in these plugins,
# but sourced transitively; override prevents any backend requirement)
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

# ---------------------------------------------------------------------------
# SPEC-1: deploy plugin exists with deploy_agent_run function
# ---------------------------------------------------------------------------
if [[ -f "$PLUGIN_FILE" ]]; then
    assert_pass "[SPEC-1] deploy plugin.sh exists at expected path"
else
    assert_fail "[SPEC-1] deploy plugin.sh exists at expected path" \
        "not found: $PLUGIN_FILE"
fi

if type deploy_agent_run >/dev/null 2>&1; then
    assert_pass "[SPEC-1] deploy_agent_run function defined after source"
else
    assert_fail "[SPEC-1] deploy_agent_run function defined after source" \
        "function not found"
fi

# ---------------------------------------------------------------------------
# SPEC-2: ZBUILD_DRY_RUN=1 writes deploy-result.json with verdict=deployed
# ---------------------------------------------------------------------------
_run2="$TEST_TEMP_DIR/run2"
_sf2="$(_make_state "$_run2")"
printf 'https://github.com/test/repo/pull/42\n' > "$_run2/artifacts/pr-url.txt"

ZBUILD_DRY_RUN=1 _deploy_agent_run_inner "$_sf2"
_dry_verdict2="$(jq -r '.verdict' "$_run2/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-2] dry-run writes verdict=deployed" "deployed" "$_dry_verdict2"

# ---------------------------------------------------------------------------
# SPEC-3: missing pr-url.txt → deploy_agent_run rc!=0
# ---------------------------------------------------------------------------
_run3="$TEST_TEMP_DIR/run3"
_sf3="$(_make_state "$_run3")"
# Do NOT create pr-url.txt

_rc3=0
_deploy_agent_run_inner "$_sf3" || _rc3=$?
assert_gt "[SPEC-3] missing pr-url.txt → rc != 0" "$_rc3" "0"

_v3="$(jq -r '.verdict' "$_run3/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-3] missing pr-url.txt → verdict=error in output" "error" "$_v3"

# ---------------------------------------------------------------------------
# SPEC-4: gate-aggregator verdict=fail → verdict=skipped in deploy-result.json
# ---------------------------------------------------------------------------
_run4="$TEST_TEMP_DIR/run4"
_sf4="$(_make_state "$_run4")"
printf 'https://github.com/test/repo/pull/42\n' > "$_run4/artifacts/pr-url.txt"
printf '{"verdict":"fail","reason":"test failure"}\n' \
    > "$_run4/artifacts/gate-aggregator-result.json"

_deploy_agent_run_inner "$_sf4"
_v4="$(jq -r '.verdict' "$_run4/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-4] gate verdict=fail → deploy-result verdict=skipped" "skipped" "$_v4"

# gate verdict=route_design (non-pass, non-fail) must also skip — fail-closed
# allowlist proceeds ONLY on an explicit pass (Copilot review).
_run4b="$TEST_TEMP_DIR/run4b"
_sf4b="$(_make_state "$_run4b")"
printf 'https://github.com/test/repo/pull/42\n' > "$_run4b/artifacts/pr-url.txt"
printf '{"verdict":"route_design"}\n' > "$_run4b/artifacts/gate-aggregator-result.json"
_deploy_agent_run_inner "$_sf4b"
_v4b="$(jq -r '.verdict' "$_run4b/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-4] gate verdict=route_design (non-pass) → skipped (allowlist)" "skipped" "$_v4b"

# ---------------------------------------------------------------------------
# SPEC-5: deploy plugin has "Role: deploy_agent" preamble comment
# ---------------------------------------------------------------------------
if grep -q "Role: deploy_agent" "$PLUGIN_FILE"; then
    assert_pass "[SPEC-5] deploy plugin has 'Role: deploy_agent' preamble comment"
else
    assert_fail "[SPEC-5] deploy plugin has 'Role: deploy_agent' preamble comment" \
        "line not found in $PLUGIN_FILE"
fi

# ---------------------------------------------------------------------------
# SPEC-6: deploy plugin does NOT contain a route_to_model call in executable code
# ---------------------------------------------------------------------------
# Strip comment lines before checking — the plugin may mention route_to_model
# in documentation comments; we only reject actual function calls in code.
_code_lines6="$(grep -v '^[[:space:]]*#' "$PLUGIN_FILE" || true)"
if grep -q "route_to_model" <<< "$_code_lines6"; then
    assert_fail "[SPEC-6] deploy plugin must not call route_to_model (T0 no-LLM invariant)" \
        "route_to_model call found in non-comment code in $PLUGIN_FILE"
else
    assert_pass "[SPEC-6] deploy plugin has no route_to_model call in executable code"
fi

# ---------------------------------------------------------------------------
# SPEC-7: dry-run deploy-result.json carries schema_version=1 field
# ---------------------------------------------------------------------------
_run7="$TEST_TEMP_DIR/run7"
_sf7="$(_make_state "$_run7")"
printf 'https://github.com/test/repo/pull/42\n' > "$_run7/artifacts/pr-url.txt"

ZBUILD_DRY_RUN=1 _deploy_agent_run_inner "$_sf7"
_sv7="$(jq -r '.schema_version' "$_run7/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-7] deploy-result.json has schema_version=1" "1" "$_sv7"

# ---------------------------------------------------------------------------
# SPEC-8: gate result MISSING (non-dry-run) → fail-closed rc=2 + verdict=error
# (#757 review fix — a missing gate must be refused, not silently skipped)
# ---------------------------------------------------------------------------
_run8="$TEST_TEMP_DIR/run8"
_sf8="$(_make_state "$_run8")"
printf 'https://github.com/test/repo/pull/42\n' > "$_run8/artifacts/pr-url.txt"
# Do NOT create gate-aggregator-result.json

_rc8=0
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_sf8" || _rc8=$?
assert_eq "[SPEC-8] missing gate (non-dry-run) → fail-closed rc=2" "2" "$_rc8"
_v8="$(jq -r '.verdict' "$_run8/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-8] missing gate → verdict=error" "error" "$_v8"

# ─── Delegation mock test ────────────────────────────────────────────────────
# Verify that when ZBUILD_DRY_RUN=0 and pr-url.txt is present, the agent
# delegates to deploy_release_run. We mock the function via the load guard.
_ZBUILD_DEPLOY_RELEASE_LOADED=1  # prevent the real tool plugin from being sourced
_MOCK_DR_CALLED=0
_MOCK_DR_RC=0
deploy_release_run() {
    _MOCK_DR_CALLED=1
    local _state_file="${2:-}"
    local _artifacts_dir; _artifacts_dir="$(dirname "$_state_file")/artifacts"
    printf '{"schema_version":1,"verdict":"deployed","tag":"test-tag","pr_url":"https://test"}\n' \
        > "$_artifacts_dir/deploy-result.json"
    return "$_MOCK_DR_RC"
}

_run_d="$TEST_TEMP_DIR/run_delegate"
_sf_d="$(_make_state "$_run_d")"
printf 'https://github.com/test/repo/pull/42\n' > "$_run_d/artifacts/pr-url.txt"
# gate present + passing → deploy proceeds to delegation (fail-closed needs a gate)
printf '{"verdict":"pass"}\n' > "$_run_d/artifacts/gate-aggregator-result.json"

ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_sf_d"
assert_eq "[SPEC-2] non-dry-run with passing gate delegates to deploy_release_run" "1" "$_MOCK_DR_CALLED"

# ─── Cleanup ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
