#!/usr/bin/env bash
# Tests: plugins/agent/validate — validate stage agent unit tests (issue #757, #1845)
#
# Covers: SPEC-8..22 (validate plugin contract, v2 migration)
# SPEC-8:  validate plugin exists with validate_agent_run function
# SPEC-9:  ZBUILD_DRY_RUN=1 writes validate-result.json with verdict=healthy
# SPEC-10: missing deploy-result.json → validate_agent_run rc!=0
# SPEC-11: successful health probe (health_check_run rc=0) → verdict=healthy
# SPEC-12: failed health probe (health_check_run rc!=0) → verdict=error
# SPEC-13: validate plugin has legacy-citation in header comment
# SPEC-14: every terminal exit path of _validate_agent_run_inner writes a result
#          file containing all four mandatory v2 keys — result_contract=2,
#          verdict, disposition, and reason
# SPEC-15: manifest provides block carries result_contract: 2
# SPEC-16: plugin.sh resolves the deploy_result input path from ZBUILD_STAGE_INPUTS
#          (jq .inputs.deploy_result) — no hardcoded $artifacts_dir/deploy-result.json
# SPEC-17: a failed health probe (hc_rc != 0) causes validate_agent_run to return
#          non-zero — the #757 fail-closed invariant is preserved under v2
# SPEC-18: all non-zero exits from plugin.sh use rc=1 — no exit path returns rc=2+
# SPEC-19: manifest config.valid_verdicts declares exactly [healthy, error];
#          test covers healthy and error via passing assertions
# SPEC-20: manifest has no config.router block — manifest_router_knob returns empty
#          for timeout_s and max_turns (correct posture for a non-routing stage)
# SPEC-21: a dry-run invocation with a valid deploy-result writes validate-result.json
#          with result_contract=2, verdict=healthy, disposition=complete, reason
#          present, and data={}; schema_version key is absent
# SPEC-22: manifest outputs array declares validate_result with primary: true
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: validate agent (kind:agent, ADR-018 P1, issue #757)"

setup_test_env "plugin-validate"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
# These were real issue numbers used as run identity.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export ZBUILD_RUN_ID="validate-test-$$"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_ISSUE="$_ZB_ID"

PLUGIN_FILE="$REPO_ROOT/plugins/agent/validate/plugin.sh"
MANIFEST_FILE="$REPO_ROOT/plugins/agent/validate/manifest.yaml"

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
    printf '{"issue":"$_ZB_ID","run_id":"%s"}\n' "$ZBUILD_RUN_ID" > "$dir/state.json"
    printf '%s\n' "$dir/state.json"
}

# ─── Helper: write a stage-inputs.json for ZBUILD_STAGE_INPUTS ───────────────
_make_stage_inputs() {
    local deploy_result_path="$1" out_file="$2"
    printf '{"inputs":{"deploy_result":"%s"}}\n' "$deploy_result_path" > "$out_file"
    printf '%s\n' "$out_file"
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

# ─── Helper: assert all four mandatory v2 result keys are present ─────────────
# Callers pass the full bracketed tag, e.g. "[SPEC-14]", so the literal tag
# string appears in the source file and is visible to static spec-coverage scans.
_assert_v2_result() {
    local tag="$1" label="$2" file="$3"
    local _rc _verd _disp _rsn
    _rc="$(jq -r '.result_contract // empty' "$file" 2>/dev/null || echo "")"
    assert_eq "$tag $label — result_contract=2" "2" "$_rc"
    _verd="$(jq -r '.verdict // empty' "$file" 2>/dev/null || echo "")"
    [[ -n "$_verd" ]] \
        && assert_pass "$tag $label — verdict key present" \
        || assert_fail "$tag $label — verdict key present" "verdict absent or null in $file"
    _disp="$(jq -r '.disposition // empty' "$file" 2>/dev/null || echo "")"
    [[ -n "$_disp" ]] \
        && assert_pass "$tag $label — disposition key present" \
        || assert_fail "$tag $label — disposition key present" "disposition absent or null in $file"
    _rsn="$(jq -r '.reason // empty' "$file" 2>/dev/null || echo "")"
    [[ -n "$_rsn" ]] \
        && assert_pass "$tag $label — reason key present" \
        || assert_fail "$tag $label — reason key present" "reason absent or null in $file"
}

# ---------------------------------------------------------------------------
# SPEC-8: validate plugin exists with validate_agent_run function
# ---------------------------------------------------------------------------
if [[ -f "$PLUGIN_FILE" ]]; then
    assert_pass "validate plugin.sh exists at expected path"
else
    assert_fail "validate plugin.sh exists at expected path" \
        "not found: $PLUGIN_FILE"
fi

if type validate_agent_run >/dev/null 2>&1; then
    assert_pass "validate_agent_run function defined after source"
else
    assert_fail "validate_agent_run function defined after source" \
        "function not found"
fi

# ---------------------------------------------------------------------------
# SPEC-9: ZBUILD_DRY_RUN=1 writes validate-result.json with verdict=healthy
# SPEC-14: dry-run exit path writes all four mandatory v2 keys
# ---------------------------------------------------------------------------
_run9="$TEST_TEMP_DIR/run9"
_sf9="$(_make_state "$_run9")"
printf '{"schema_version":1,"verdict":"deployed","mode":"dry_run"}\n' \
    > "$_run9/artifacts/deploy-result.json"
_si9="$TEST_TEMP_DIR/stage-inputs-9.json"
_make_stage_inputs "$_run9/artifacts/deploy-result.json" "$_si9" > /dev/null

ZBUILD_STAGE_INPUTS="$_si9" ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$_sf9"
_v9="$(jq -r '.verdict' "$_run9/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "dry-run writes verdict=healthy" "healthy" "$_v9"

# SPEC-14: dry-run exit path writes all four v2 mandatory keys
_assert_v2_result "[SPEC-14]" "dry-run exit" "$_run9/artifacts/validate-result.json"

# ---------------------------------------------------------------------------
# SPEC-10: missing deploy-result.json → validate_agent_run rc!=0
# SPEC-14: missing-input exit path writes all four mandatory v2 keys
# ---------------------------------------------------------------------------
_run10="$TEST_TEMP_DIR/run10"
_sf10="$(_make_state "$_run10")"
# Do NOT create deploy-result.json — ZBUILD_STAGE_INPUTS points to the absent path
_si10="$TEST_TEMP_DIR/stage-inputs-10.json"
_make_stage_inputs "$_run10/artifacts/deploy-result.json" "$_si10" > /dev/null

_rc10=0
ZBUILD_STAGE_INPUTS="$_si10" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf10" || _rc10=$?
assert_gt "missing deploy-result.json → rc != 0" "$_rc10" "0"

_v10="$(jq -r '.verdict' "$_run10/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "missing deploy-result.json → verdict=error in output" "error" "$_v10"

# SPEC-14: missing-input exit path writes all four v2 mandatory keys
_assert_v2_result "[SPEC-14]" "missing-input exit" "$_run10/artifacts/validate-result.json"

# ---------------------------------------------------------------------------
# SPEC-11: successful health probe (rc=0) → verdict=healthy in validate-result.json
# SPEC-14: healthy-probe exit path writes all four mandatory v2 keys
# ---------------------------------------------------------------------------
_run11="$TEST_TEMP_DIR/run11"
_sf11="$(_make_state "$_run11")"
printf '{"schema_version":1,"verdict":"deployed"}\n' \
    > "$_run11/artifacts/deploy-result.json"
_si11="$TEST_TEMP_DIR/stage-inputs-11.json"
_make_stage_inputs "$_run11/artifacts/deploy-result.json" "$_si11" > /dev/null

_MOCK_HC_RC=0  # probe succeeds
ZBUILD_STAGE_INPUTS="$_si11" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf11"
_v11="$(jq -r '.verdict' "$_run11/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "healthy probe → verdict=healthy" "healthy" "$_v11"

# SPEC-14: healthy-probe exit path writes all four v2 mandatory keys
_assert_v2_result "[SPEC-14]" "healthy-probe exit" "$_run11/artifacts/validate-result.json"

# ---------------------------------------------------------------------------
# SPEC-12: failed health probe (rc!=0) → verdict=error in validate-result.json
# SPEC-14: failed-probe exit path writes all four mandatory v2 keys
# ---------------------------------------------------------------------------
_run12="$TEST_TEMP_DIR/run12"
_sf12="$(_make_state "$_run12")"
printf '{"schema_version":1,"verdict":"deployed"}\n' \
    > "$_run12/artifacts/deploy-result.json"
_si12="$TEST_TEMP_DIR/stage-inputs-12.json"
_make_stage_inputs "$_run12/artifacts/deploy-result.json" "$_si12" > /dev/null

_MOCK_HC_RC=1  # probe fails
_rc12=0
ZBUILD_STAGE_INPUTS="$_si12" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf12" || _rc12=$?
_v12="$(jq -r '.verdict' "$_run12/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "failed probe → verdict=error" "error" "$_v12"
# #757 review fix: a failed probe must PROPAGATE a non-zero rc (was unconditional 0).
assert_gt "failed probe → rc propagated (rc != 0)" "$_rc12" "0"

# SPEC-14: failed-probe exit path writes all four v2 mandatory keys
_assert_v2_result "[SPEC-14]" "failed-probe exit" "$_run12/artifacts/validate-result.json"

_MOCK_HC_RC=0  # reset

# ---------------------------------------------------------------------------
# SPEC-13: validate plugin has legacy-citation in header comment
# ---------------------------------------------------------------------------
if grep -q "legacy-citation" "$PLUGIN_FILE"; then
    assert_pass "validate plugin has legacy-citation in header"
else
    assert_fail "validate plugin has legacy-citation in header" \
        "legacy-citation not found in $PLUGIN_FILE"
fi

# Verify the specific cited file
if grep -q "pipeline-stages-monitor.sh" "$PLUGIN_FILE"; then
    assert_pass "legacy-citation references pipeline-stages-monitor.sh"
else
    assert_fail "legacy-citation references pipeline-stages-monitor.sh" \
        "pipeline-stages-monitor.sh not found in legacy-citation"
fi

# ---------------------------------------------------------------------------
# SPEC-15: manifest provides block carries result_contract: 2
# ---------------------------------------------------------------------------
_provides_rc="$(awk '
    /^provides:/{p=1; next}
    p && /^[a-zA-Z]/{p=0}
    p && /result_contract:/{print $2; exit}
' "$MANIFEST_FILE")"
assert_eq "[SPEC-15] manifest provides block carries result_contract: 2" "2" "$_provides_rc"

# ---------------------------------------------------------------------------
# SPEC-16: plugin.sh resolves deploy_result from ZBUILD_STAGE_INPUTS
#          (jq .inputs.deploy_result) — no hardcoded $artifacts_dir/deploy-result.json
# ---------------------------------------------------------------------------

# Structural check: hardcoded path construction must not remain in plugin.sh
if grep -qE '\$\{?artifacts_dir\}?/deploy-result\.json' "$PLUGIN_FILE"; then
    assert_fail "[SPEC-16] plugin.sh has no hardcoded \$artifacts_dir/deploy-result.json path construction" \
        "hardcoded path found in $PLUGIN_FILE"
else
    assert_pass "[SPEC-16] plugin.sh has no hardcoded \$artifacts_dir/deploy-result.json path construction"
fi

# Behavioral check: put deploy-result at a non-standard path; plugin must find it
# via ZBUILD_STAGE_INPUTS, not via the old hardcoded artifacts_dir path.
_run16="$TEST_TEMP_DIR/run16"
_sf16="$(_make_state "$_run16")"
# Deploy-result is intentionally NOT under artifacts/ — hardcoded path would miss it.
mkdir -p "$_run16/inputs"
printf '{"schema_version":1,"verdict":"deployed"}\n' > "$_run16/inputs/deploy-result.json"
_si16="$TEST_TEMP_DIR/stage-inputs-16.json"
_make_stage_inputs "$_run16/inputs/deploy-result.json" "$_si16" > /dev/null

_MOCK_HC_RC=0
ZBUILD_STAGE_INPUTS="$_si16" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf16" || true
_v16="$(jq -r '.verdict' "$_run16/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-16] deploy_result resolved from ZBUILD_STAGE_INPUTS non-standard path → verdict=healthy" \
    "healthy" "$_v16"

# ---------------------------------------------------------------------------
# SPEC-17: a failed health probe causes validate_agent_run (outer) to return
#          non-zero — the #757 fail-closed invariant is preserved under v2
# ---------------------------------------------------------------------------
_run17="$TEST_TEMP_DIR/run17"
_sf17="$(_make_state "$_run17")"
printf '{"schema_version":1,"verdict":"deployed"}\n' \
    > "$_run17/artifacts/deploy-result.json"
_si17="$TEST_TEMP_DIR/stage-inputs-17.json"
_make_stage_inputs "$_run17/artifacts/deploy-result.json" "$_si17" > /dev/null

_MOCK_HC_RC=1  # probe fails
_rc17=0
ZBUILD_STAGE_INPUTS="$_si17" ZBUILD_DRY_RUN=0 validate_agent_run "" "$_sf17" || _rc17=$?
assert_gt "[SPEC-17] failed health probe → validate_agent_run rc != 0" "$_rc17" "0"
_MOCK_HC_RC=0  # reset

# ---------------------------------------------------------------------------
# SPEC-18: all non-zero exits from plugin.sh use rc=1 — no exit path returns
#          rc=2 or higher
# ---------------------------------------------------------------------------

# Path A: missing required input → exactly rc=1 (currently returns rc=2)
_run18a="$TEST_TEMP_DIR/run18a"
_sf18a="$(_make_state "$_run18a")"
# Do NOT create deploy-result.json
_si18a="$TEST_TEMP_DIR/stage-inputs-18a.json"
_make_stage_inputs "$_run18a/artifacts/deploy-result.json" "$_si18a" > /dev/null
_rc18a=0
ZBUILD_STAGE_INPUTS="$_si18a" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf18a" || _rc18a=$?
assert_eq "[SPEC-18] missing-input exit → exactly rc=1" "1" "$_rc18a"

# Path B: probe returning rc=2 → plugin must clamp to rc=1 (currently returns rc=2)
_run18b="$TEST_TEMP_DIR/run18b"
_sf18b="$(_make_state "$_run18b")"
printf '{"schema_version":1,"verdict":"deployed"}\n' \
    > "$_run18b/artifacts/deploy-result.json"
_si18b="$TEST_TEMP_DIR/stage-inputs-18b.json"
_make_stage_inputs "$_run18b/artifacts/deploy-result.json" "$_si18b" > /dev/null
_MOCK_HC_RC=2  # hc returns rc=2; plugin must NOT propagate that directly
_rc18b=0
ZBUILD_STAGE_INPUTS="$_si18b" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf18b" || _rc18b=$?
assert_eq "[SPEC-18] probe rc=2 → plugin exit clamps to rc=1" "1" "$_rc18b"
_MOCK_HC_RC=0  # reset

# Path C: missing state_file in outer wrapper → exactly rc=1 (currently returns rc=2)
mkdir -p "$TEST_TEMP_DIR/run18c/artifacts"
_rc18c=0
ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/run18c/artifacts" ZBUILD_STAGE_INPUTS="" \
    validate_agent_run "" "" || _rc18c=$?
assert_eq "[SPEC-18] missing state_file → validate_agent_run exactly rc=1" "1" "$_rc18c"

# ---------------------------------------------------------------------------
# SPEC-19: manifest config.valid_verdicts declares exactly [healthy, error];
#          validate-test.sh covers healthy (SPEC-11, SPEC-21) and error (SPEC-10,
#          SPEC-12) via passing assertions above
# ---------------------------------------------------------------------------

# Extract the valid_verdicts entries from the config block, sort, and join
_vv="$(awk '
    /^config:/{in_c=1; next}
    in_c && /^[a-zA-Z]/{in_c=0}
    in_c && /valid_verdicts:/{in_vv=1; next}
    in_vv && /^    - /{v=$2; gsub(/[[:space:]]/, "", v); print v; next}
    in_vv && /^  [a-z]/{in_vv=0}
' "$MANIFEST_FILE" | sort | paste -sd,)"
assert_eq "[SPEC-19] manifest config.valid_verdicts declares exactly [healthy, error]" \
    "error,healthy" "$_vv"

# SPEC-19 also mandates that validate-test.sh covers both verdicts via passing
# assertions — verify here using results from the SPEC-11 and SPEC-12 runs above.
assert_eq "[SPEC-19] validate-test.sh covers healthy verdict (SPEC-11 run)" \
    "healthy" "$_v11"
assert_eq "[SPEC-19] validate-test.sh covers error verdict (SPEC-12 run)" \
    "error" "$_v12"

# ---------------------------------------------------------------------------
# SPEC-20: manifest has no config.router block — manifest_router_knob returns
#          empty for timeout_s and max_turns (non-routing stage posture, ADR-017)
# ---------------------------------------------------------------------------

# Extract the config block and verify no router: key is present
_config_block="$(awk '/^config:/{p=1; next} p && /^[a-zA-Z]/{p=0} p{print}' "$MANIFEST_FILE")"
if grep -q 'router:' <<< "$_config_block"; then
    assert_fail "[SPEC-20] manifest has no config.router block" \
        "config.router block found in manifest"
else
    assert_pass "[SPEC-20] manifest has no config.router block"
fi

# Source manifest-router-budget.sh (has its own load guard)
# shellcheck source=../../../../core/plugin-registry/manifest-router-budget.sh
source "$REPO_ROOT/core/plugin-registry/manifest-router-budget.sh"

_ts="$(manifest_router_knob "$MANIFEST_FILE" "timeout_s" 2>/dev/null || true)"
[[ -z "$_ts" ]] \
    && assert_pass "[SPEC-20] manifest_router_knob timeout_s returns empty (no router block)" \
    || assert_fail "[SPEC-20] manifest_router_knob timeout_s returns empty (no router block)" \
        "expected empty, got: $_ts"

_mt="$(manifest_router_knob "$MANIFEST_FILE" "max_turns" 2>/dev/null || true)"
[[ -z "$_mt" ]] \
    && assert_pass "[SPEC-20] manifest_router_knob max_turns returns empty (no router block)" \
    || assert_fail "[SPEC-20] manifest_router_knob max_turns returns empty (no router block)" \
        "expected empty, got: $_mt"

# ---------------------------------------------------------------------------
# SPEC-21: a dry-run invocation with a valid deploy-result writes
#          validate-result.json with result_contract=2, verdict=healthy,
#          disposition=complete, reason present, and data={}; schema_version absent
# ---------------------------------------------------------------------------
_run21="$TEST_TEMP_DIR/run21"
_sf21="$(_make_state "$_run21")"
printf '{"schema_version":1,"verdict":"deployed","mode":"dry_run"}\n' \
    > "$_run21/artifacts/deploy-result.json"
_si21="$TEST_TEMP_DIR/stage-inputs-21.json"
_make_stage_inputs "$_run21/artifacts/deploy-result.json" "$_si21" > /dev/null

ZBUILD_STAGE_INPUTS="$_si21" ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$_sf21"
_r21="$_run21/artifacts/validate-result.json"

_v21_rc="$(jq -r '.result_contract' "$_r21" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-21] dry-run v2 output: result_contract=2" "2" "$_v21_rc"

_v21_verd="$(jq -r '.verdict' "$_r21" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-21] dry-run v2 output: verdict=healthy" "healthy" "$_v21_verd"

_v21_disp="$(jq -r '.disposition' "$_r21" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-21] dry-run v2 output: disposition=complete" "complete" "$_v21_disp"

_v21_reason="$(jq 'has("reason")' "$_r21" 2>/dev/null || echo false)"
assert_eq "[SPEC-21] dry-run v2 output: reason key present" "true" "$_v21_reason"

_v21_data="$(jq '.data == {}' "$_r21" 2>/dev/null || echo false)"
assert_eq "[SPEC-21] dry-run v2 output: data={}" "true" "$_v21_data"

_v21_sv="$(jq 'has("schema_version")' "$_r21" 2>/dev/null || echo false)"
assert_eq "[SPEC-21] dry-run v2 output: schema_version key absent" "false" "$_v21_sv"

# ---------------------------------------------------------------------------
# SPEC-22: manifest outputs array declares validate_result with primary: true —
#          this invariant must not regress under v2 migration
# ---------------------------------------------------------------------------
_v22_block="$(grep -A 10 'id: validate_result' "$MANIFEST_FILE")"
if grep -q 'primary:.*true' <<< "$_v22_block"; then
    assert_pass "[SPEC-22] manifest outputs validate_result declares primary: true"
else
    assert_fail "[SPEC-22] manifest outputs validate_result declares primary: true" \
        "primary: true not found near id: validate_result in manifest"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
