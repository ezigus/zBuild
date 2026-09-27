#!/usr/bin/env bash
# Tests: plugins/agent/validate — validate stage agent unit tests (issue #757)
#
# Covers: SPEC-8..13 (validate plugin contract)
#         SPEC-14..22 (v2 contract migration — issue #1845)
# SPEC-8:  validate plugin exists with validate_agent_run function
# SPEC-9:  ZBUILD_DRY_RUN=1 writes validate-result.json with verdict=healthy
# SPEC-10: missing deploy-result.json → validate_agent_run rc!=0
# SPEC-11: successful health probe (health_check_run rc=0) → verdict=healthy
# SPEC-12: failed health probe (health_check_run rc!=0) → verdict=error
# SPEC-13: validate plugin has legacy-citation in header comment
# SPEC-14: every terminal exit path writes result file with all four v2 keys
# SPEC-15: manifest provides block carries result_contract: 2
# SPEC-16: deploy_result path resolved from ZBUILD_STAGE_INPUTS, not hardcoded
# SPEC-17: failed health probe → validate_agent_run (outer) returns non-zero
# SPEC-18: all non-zero exits from plugin.sh use rc=1
# SPEC-19: manifest valid_verdicts declares exactly [healthy, error]
# SPEC-20: manifest has no config.router block
# SPEC-21: dry-run writes validate-result.json with full v2 shape, no schema_version
# SPEC-22: manifest outputs declares validate_result with primary: true
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: validate agent (kind:agent, ADR-018 P1, issue #757, v2 #1845)"

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

# ─── Helper: write a ZBUILD_STAGE_INPUTS index for validate ──────────────────
_make_stage_inputs() {
    local index_path="$1"
    local deploy_result_path="$2"
    printf '{"schema_version":1,"stage":"validate","inputs":{"deploy_result":"%s"}}\n' \
        "$deploy_result_path" > "$index_path"
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
# ---------------------------------------------------------------------------
_run9="$TEST_TEMP_DIR/run9"
_sf9="$(_make_state "$_run9")"
printf '{"schema_version":1,"verdict":"deployed","mode":"dry_run"}\n' \
    > "$_run9/artifacts/deploy-result.json"
_si9="$TEST_TEMP_DIR/si9.json"
_make_stage_inputs "$_si9" "$_run9/artifacts/deploy-result.json"

ZBUILD_STAGE_INPUTS="$_si9" ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$_sf9"
_v9="$(jq -r '.verdict' "$_run9/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "dry-run writes verdict=healthy" "healthy" "$_v9"

# ---------------------------------------------------------------------------
# SPEC-10: missing deploy-result.json → validate_agent_run rc!=0
# ---------------------------------------------------------------------------
_run10="$TEST_TEMP_DIR/run10"
_sf10="$(_make_state "$_run10")"
_si10="$TEST_TEMP_DIR/si10.json"
_make_stage_inputs "$_si10" "$_run10/artifacts/deploy-result.json"
# Do NOT create deploy-result.json

_rc10=0
ZBUILD_STAGE_INPUTS="$_si10" _validate_agent_run_inner "$_sf10" || _rc10=$?
assert_gt "missing deploy-result.json → rc != 0" "$_rc10" "0"

_v10="$(jq -r '.verdict' "$_run10/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "missing deploy-result.json → verdict=error in output" "error" "$_v10"

# ---------------------------------------------------------------------------
# SPEC-11: successful health probe (rc=0) → verdict=healthy in validate-result.json
# ---------------------------------------------------------------------------
_run11="$TEST_TEMP_DIR/run11"
_sf11="$(_make_state "$_run11")"
printf '{"schema_version":1,"verdict":"deployed"}\n' \
    > "$_run11/artifacts/deploy-result.json"
_si11="$TEST_TEMP_DIR/si11.json"
_make_stage_inputs "$_si11" "$_run11/artifacts/deploy-result.json"

_MOCK_HC_RC=0  # probe succeeds
ZBUILD_STAGE_INPUTS="$_si11" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf11"
_v11="$(jq -r '.verdict' "$_run11/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "healthy probe → verdict=healthy" "healthy" "$_v11"

# ---------------------------------------------------------------------------
# SPEC-12: failed health probe (rc!=0) → verdict=error in validate-result.json
# ---------------------------------------------------------------------------
_run12="$TEST_TEMP_DIR/run12"
_sf12="$(_make_state "$_run12")"
printf '{"schema_version":1,"verdict":"deployed"}\n' \
    > "$_run12/artifacts/deploy-result.json"
_si12="$TEST_TEMP_DIR/si12.json"
_make_stage_inputs "$_si12" "$_run12/artifacts/deploy-result.json"

_MOCK_HC_RC=1  # probe fails
_rc12=0
ZBUILD_STAGE_INPUTS="$_si12" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf12" || _rc12=$?
_v12="$(jq -r '.verdict' "$_run12/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "failed probe → verdict=error" "error" "$_v12"
# #757 review fix: a failed probe must PROPAGATE a non-zero rc (was unconditional 0).
assert_gt "failed probe → rc propagated (rc != 0)" "$_rc12" "0"
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

# ===========================================================================
# SPEC-14: every terminal exit path of _validate_agent_run_inner writes a
# result file containing all four mandatory v2 keys:
#   result_contract=2, verdict, disposition, reason
# ===========================================================================

_assert_v2_keys() {
    local label="$1" result_file="$2"
    local rc2 verd disp reason
    rc2="$(jq -r '.result_contract // "MISSING"' "$result_file" 2>/dev/null || echo MISSING)"
    verd="$(jq -r '.verdict // "MISSING"' "$result_file" 2>/dev/null || echo MISSING)"
    disp="$(jq -r '.disposition // "MISSING"' "$result_file" 2>/dev/null || echo MISSING)"
    reason="$(jq -r '.reason // "MISSING"' "$result_file" 2>/dev/null || echo MISSING)"
    assert_eq "[SPEC-14] $label → result_contract=2" "2" "$rc2"
    if [[ "$verd" != "MISSING" && -n "$verd" ]]; then
        assert_pass "[SPEC-14] $label → verdict present"
    else
        assert_fail "[SPEC-14] $label → verdict present" "verdict key absent or empty"
    fi
    if [[ "$disp" != "MISSING" && -n "$disp" ]]; then
        assert_pass "[SPEC-14] $label → disposition present"
    else
        assert_fail "[SPEC-14] $label → disposition present" "disposition key absent or empty"
    fi
    if [[ "$reason" != "MISSING" && -n "$reason" ]]; then
        assert_pass "[SPEC-14] $label → reason present"
    else
        assert_fail "[SPEC-14] $label → reason present" "reason key absent or empty"
    fi
}

# Path A: missing deploy-result
_run14a="$TEST_TEMP_DIR/run14a"
_sf14a="$(_make_state "$_run14a")"
_si14a="$TEST_TEMP_DIR/si14a.json"
_make_stage_inputs "$_si14a" "$_run14a/artifacts/deploy-result.json"
ZBUILD_STAGE_INPUTS="$_si14a" _validate_agent_run_inner "$_sf14a" || true
_assert_v2_keys "missing-deploy-result" "$_run14a/artifacts/validate-result.json"

# Path B: dry-run
_run14b="$TEST_TEMP_DIR/run14b"
_sf14b="$(_make_state "$_run14b")"
printf '{"result_contract":2,"verdict":"deployed"}\n' > "$_run14b/artifacts/deploy-result.json"
_si14b="$TEST_TEMP_DIR/si14b.json"
_make_stage_inputs "$_si14b" "$_run14b/artifacts/deploy-result.json"
ZBUILD_STAGE_INPUTS="$_si14b" ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$_sf14b" || true
_assert_v2_keys "dry-run" "$_run14b/artifacts/validate-result.json"

# Path C: probe success
_run14c="$TEST_TEMP_DIR/run14c"
_sf14c="$(_make_state "$_run14c")"
printf '{"result_contract":2,"verdict":"deployed"}\n' > "$_run14c/artifacts/deploy-result.json"
_si14c="$TEST_TEMP_DIR/si14c.json"
_make_stage_inputs "$_si14c" "$_run14c/artifacts/deploy-result.json"
_MOCK_HC_RC=0
ZBUILD_STAGE_INPUTS="$_si14c" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf14c" || true
_assert_v2_keys "probe-success" "$_run14c/artifacts/validate-result.json"

# Path D: probe failure
_run14d="$TEST_TEMP_DIR/run14d"
_sf14d="$(_make_state "$_run14d")"
printf '{"result_contract":2,"verdict":"deployed"}\n' > "$_run14d/artifacts/deploy-result.json"
_si14d="$TEST_TEMP_DIR/si14d.json"
_make_stage_inputs "$_si14d" "$_run14d/artifacts/deploy-result.json"
_MOCK_HC_RC=1
ZBUILD_STAGE_INPUTS="$_si14d" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf14d" || true
_assert_v2_keys "probe-failure" "$_run14d/artifacts/validate-result.json"
_MOCK_HC_RC=0

# Path E: health-check plugin missing (override _VALIDATE_ROOT to a dir without the plugin)
_run14e="$TEST_TEMP_DIR/run14e"
_sf14e="$(_make_state "$_run14e")"
printf '{"result_contract":2,"verdict":"deployed"}\n' > "$_run14e/artifacts/deploy-result.json"
_si14e="$TEST_TEMP_DIR/si14e.json"
_make_stage_inputs "$_si14e" "$_run14e/artifacts/deploy-result.json"
(
    _VALIDATE_ROOT="$TEST_TEMP_DIR/no_hc_root"
    _ZBUILD_HEALTH_CHECK_LOADED=""
    unset -f health_check_run 2>/dev/null || true
    ZBUILD_STAGE_INPUTS="$_si14e" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf14e"
) || true
_assert_v2_keys "hc-plugin-missing" "$_run14e/artifacts/validate-result.json"

# ===========================================================================
# SPEC-15: manifest provides block carries result_contract: 2
# ===========================================================================
_rc2_in_provides="$(awk '
    /^provides:/ { in_p=1; next }
    in_p && /^[a-z_]/ { in_p=0 }
    in_p && /result_contract:[[:space:]]*2/ { print "found"; exit }
' "$MANIFEST_FILE")"
if [[ "$_rc2_in_provides" == "found" ]]; then
    assert_pass "[SPEC-15] manifest provides block carries result_contract: 2"
else
    assert_fail "[SPEC-15] manifest provides block carries result_contract: 2" \
        "result_contract: 2 not found within provides: block in $MANIFEST_FILE"
fi

# ===========================================================================
# SPEC-16: plugin.sh resolves deploy_result path from ZBUILD_STAGE_INPUTS
# (jq .inputs.deploy_result) — no hardcoded path construction
# ===========================================================================
_run16="$TEST_TEMP_DIR/run16"
_sf16="$(_make_state "$_run16")"
# Place deploy-result at a custom path that does NOT match $artifacts_dir/deploy-result.json
mkdir -p "$_run16/custom-inputs"
printf '{"result_contract":2,"verdict":"deployed"}\n' > "$_run16/custom-inputs/deploy-result.json"
_si16="$TEST_TEMP_DIR/si16.json"
_make_stage_inputs "$_si16" "$_run16/custom-inputs/deploy-result.json"
# $artifacts_dir/deploy-result.json intentionally absent — only the custom path exists
_rc16=0
ZBUILD_STAGE_INPUTS="$_si16" ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$_sf16" || _rc16=$?
assert_eq "[SPEC-16] deploy_result resolved from ZBUILD_STAGE_INPUTS → rc=0" "0" "$_rc16"
_v16="$(jq -r '.verdict // "MISSING"' "$_run16/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-16] deploy_result from ZBUILD_STAGE_INPUTS → verdict=healthy" "healthy" "$_v16"

# Negative half: no hardcoded $artifacts_dir/deploy-result.json path construction in plugin.sh
if ! grep -qE '\$artifacts_dir/deploy-result\.json' "$PLUGIN_FILE"; then
    assert_pass "[SPEC-16] no hardcoded \$artifacts_dir/deploy-result.json in plugin.sh"
else
    assert_fail "[SPEC-16] no hardcoded \$artifacts_dir/deploy-result.json in plugin.sh" \
        "hardcoded path construction found in $PLUGIN_FILE"
fi

# ===========================================================================
# SPEC-17: a failed health probe causes validate_agent_run (outer) to return
# non-zero — the #757 fail-closed invariant is preserved under v2
# ===========================================================================
_run17="$TEST_TEMP_DIR/run17"
_sf17="$(_make_state "$_run17")"
printf '{"result_contract":2,"verdict":"deployed"}\n' > "$_run17/artifacts/deploy-result.json"
_si17="$TEST_TEMP_DIR/si17.json"
_make_stage_inputs "$_si17" "$_run17/artifacts/deploy-result.json"
_MOCK_HC_RC=1
_rc17=0
ZBUILD_STAGE_INPUTS="$_si17" ZBUILD_DRY_RUN=0 validate_agent_run "validate" "$_sf17" || _rc17=$?
assert_gt "[SPEC-17] failed probe → validate_agent_run rc != 0" "$_rc17" "0"
_MOCK_HC_RC=0

# ===========================================================================
# SPEC-18: all non-zero exits from plugin.sh use rc=1
# ===========================================================================

# Missing deploy-result → rc=1
_run18a="$TEST_TEMP_DIR/run18a"
_sf18a="$(_make_state "$_run18a")"
_si18a="$TEST_TEMP_DIR/si18a.json"
_make_stage_inputs "$_si18a" "$_run18a/artifacts/deploy-result.json"
_rc18a=0
ZBUILD_STAGE_INPUTS="$_si18a" _validate_agent_run_inner "$_sf18a" || _rc18a=$?
assert_eq "[SPEC-18] missing deploy-result → rc=1 (not 2)" "1" "$_rc18a"

# Failed probe → rc=1 (not propagated hc_rc)
_run18b="$TEST_TEMP_DIR/run18b"
_sf18b="$(_make_state "$_run18b")"
printf '{"result_contract":2,"verdict":"deployed"}\n' > "$_run18b/artifacts/deploy-result.json"
_si18b="$TEST_TEMP_DIR/si18b.json"
_make_stage_inputs "$_si18b" "$_run18b/artifacts/deploy-result.json"
_MOCK_HC_RC=1
_rc18b=0
ZBUILD_STAGE_INPUTS="$_si18b" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf18b" || _rc18b=$?
assert_eq "[SPEC-18] failed probe → rc=1 (not propagated hc_rc)" "1" "$_rc18b"
_MOCK_HC_RC=0

# hc-plugin missing → rc=1
_run18c="$TEST_TEMP_DIR/run18c"
_sf18c="$(_make_state "$_run18c")"
printf '{"result_contract":2,"verdict":"deployed"}\n' > "$_run18c/artifacts/deploy-result.json"
_si18c="$TEST_TEMP_DIR/si18c.json"
_make_stage_inputs "$_si18c" "$_run18c/artifacts/deploy-result.json"
_rc18c=0
(
    _VALIDATE_ROOT="$TEST_TEMP_DIR/no_hc_root"
    _ZBUILD_HEALTH_CHECK_LOADED=""
    unset -f health_check_run 2>/dev/null || true
    ZBUILD_STAGE_INPUTS="$_si18c" ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf18c"
) || _rc18c=$?
assert_eq "[SPEC-18] hc-plugin missing → rc=1 (not 2)" "1" "$_rc18c"

# validate_agent_run (outer) with missing state_file → rc=1
_rc18d=0
ZBUILD_STAGE_INPUTS="" validate_agent_run "validate" "" || _rc18d=$?
assert_eq "[SPEC-18] missing state_file in outer → rc=1 (not 2)" "1" "$_rc18d"

# ===========================================================================
# SPEC-19: manifest config.valid_verdicts declares exactly [healthy, error];
# validate-test.sh covers healthy (SPEC-11) and error (SPEC-12) via passing assertions
# ===========================================================================
if grep -qE "^[[:space:]]+-[[:space:]]+healthy" "$MANIFEST_FILE"; then
    assert_pass "[SPEC-19] manifest valid_verdicts contains healthy"
else
    assert_fail "[SPEC-19] manifest valid_verdicts contains healthy" \
        "healthy not found in valid_verdicts"
fi
if grep -qE "^[[:space:]]+-[[:space:]]+error" "$MANIFEST_FILE"; then
    assert_pass "[SPEC-19] manifest valid_verdicts contains error"
else
    assert_fail "[SPEC-19] manifest valid_verdicts contains error" \
        "error not found in valid_verdicts"
fi

# Count all entries in valid_verdicts to enforce "exactly 2"
_vv_count=0
while IFS= read -r _vv_line; do
    [[ -n "$_vv_line" ]] && _vv_count=$(( _vv_count + 1 ))
done < <(awk '
    /valid_verdicts:/ { in_vv=1; next }
    in_vv && /^[[:space:]]*-/ { print; next }
    in_vv && /^[[:space:]]*[^-[:space:]]/ { exit }
' "$MANIFEST_FILE")
assert_eq "[SPEC-19] manifest valid_verdicts declares exactly 2 entries (healthy and error)" "2" "$_vv_count"

# Confirm healthy and error are covered by the actual SPEC-11 / SPEC-12 run results
assert_eq "[SPEC-19] healthy verdict confirmed by SPEC-11 run" "healthy" "$_v11"
assert_eq "[SPEC-19] error verdict confirmed by SPEC-12 run" "error" "$_v12"

# ===========================================================================
# SPEC-20: manifest has no config.router block — manifest_router_knob returns
# empty string for timeout_s and max_turns (ADR-017 non-routing-stage posture)
# ===========================================================================

# shellcheck source=../../../../core/plugin-registry/manifest-router-budget.sh
source "$REPO_ROOT/core/plugin-registry/manifest-router-budget.sh"

_mrk_timeout="$(manifest_router_knob "$MANIFEST_FILE" "timeout_s" 2>/dev/null || true)"
_mrk_turns="$(manifest_router_knob "$MANIFEST_FILE" "max_turns" 2>/dev/null || true)"

if [[ -z "$_mrk_timeout" ]]; then
    assert_pass "[SPEC-20] manifest_router_knob timeout_s returns empty (no router block)"
else
    assert_fail "[SPEC-20] manifest_router_knob timeout_s returns empty (no router block)" \
        "got: $_mrk_timeout"
fi
if [[ -z "$_mrk_turns" ]]; then
    assert_pass "[SPEC-20] manifest_router_knob max_turns returns empty (no router block)"
else
    assert_fail "[SPEC-20] manifest_router_knob max_turns returns empty (no router block)" \
        "got: $_mrk_turns"
fi

# ===========================================================================
# SPEC-21: dry-run with valid deploy-result writes validate-result.json with
# result_contract=2, verdict=healthy, disposition=complete, reason present,
# data={}, and schema_version key absent
# ===========================================================================
_run21="$TEST_TEMP_DIR/run21"
_sf21="$(_make_state "$_run21")"
printf '{"result_contract":2,"verdict":"deployed"}\n' > "$_run21/artifacts/deploy-result.json"
_si21="$TEST_TEMP_DIR/si21.json"
_make_stage_inputs "$_si21" "$_run21/artifacts/deploy-result.json"

ZBUILD_STAGE_INPUTS="$_si21" ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$_sf21"

_r21_file="$_run21/artifacts/validate-result.json"
_r21_rc2="$(jq -r '.result_contract // "MISSING"' "$_r21_file" 2>/dev/null || echo MISSING)"
_r21_verd="$(jq -r '.verdict // "MISSING"' "$_r21_file" 2>/dev/null || echo MISSING)"
_r21_disp="$(jq -r '.disposition // "MISSING"' "$_r21_file" 2>/dev/null || echo MISSING)"
_r21_reason="$(jq -r '.reason // "MISSING"' "$_r21_file" 2>/dev/null || echo MISSING)"
_r21_data="$(jq -c '.data // "MISSING"' "$_r21_file" 2>/dev/null || echo MISSING)"
_r21_sv="$(jq -r '.schema_version // "ABSENT"' "$_r21_file" 2>/dev/null || echo MISSING)"

assert_eq "[SPEC-21] dry-run result_contract=2" "2" "$_r21_rc2"
assert_eq "[SPEC-21] dry-run verdict=healthy" "healthy" "$_r21_verd"
assert_eq "[SPEC-21] dry-run disposition=complete" "complete" "$_r21_disp"
if [[ "$_r21_reason" != "MISSING" && -n "$_r21_reason" ]]; then
    assert_pass "[SPEC-21] dry-run reason present"
else
    assert_fail "[SPEC-21] dry-run reason present" "reason key absent or empty"
fi
assert_eq "[SPEC-21] dry-run data={}" "{}" "$_r21_data"
assert_eq "[SPEC-21] dry-run schema_version key absent" "ABSENT" "$_r21_sv"

# ===========================================================================
# SPEC-22: manifest outputs array declares validate_result with primary: true
# ===========================================================================
_vr_primary=0
_in_outputs=0
_in_vr=0
while IFS= read -r _ml; do
    if grep -q "^outputs:" <<< "$_ml"; then
        _in_outputs=1
        continue
    fi
    if [[ $_in_outputs -eq 1 ]]; then
        # A top-level key (no leading whitespace) closes the outputs block
        if grep -qE "^[a-z]" <<< "$_ml"; then
            _in_outputs=0
            _in_vr=0
            continue
        fi
        if grep -q "id: validate_result" <<< "$_ml"; then
            _in_vr=1
            continue
        fi
        # A new output list entry resets the in_vr flag
        if [[ $_in_vr -eq 1 ]] && grep -qE "^[[:space:]]*-[[:space:]]+id:" <<< "$_ml"; then
            _in_vr=0
        fi
        if [[ $_in_vr -eq 1 ]] && grep -q "primary: true" <<< "$_ml"; then
            _vr_primary=1
        fi
    fi
done < "$MANIFEST_FILE"

if [[ $_vr_primary -eq 1 ]]; then
    assert_pass "[SPEC-22] manifest outputs declares validate_result with primary: true"
else
    assert_fail "[SPEC-22] manifest outputs declares validate_result with primary: true" \
        "primary: true not found in validate_result output block in $MANIFEST_FILE"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
