#!/usr/bin/env bash
# Tests: plugins/agent/validate — validate stage agent unit tests (issues #757, #1845)
#
# Covers: SPEC-8..13 (validate plugin contract v1 guards)
#         SPEC-14..25 (v2 contract migration acceptance)
# SPEC-8:  validate plugin exists with validate_agent_run function
# SPEC-9:  ZBUILD_DRY_RUN=1 writes validate-result.json with verdict=healthy
# SPEC-10: missing deploy-result.json → validate_agent_run rc!=0
# SPEC-11: successful health probe (health_check_run rc=0) → verdict=healthy
# SPEC-12: failed health probe (health_check_run rc!=0) → verdict=error
# SPEC-13: validate plugin has legacy-citation in header comment
# SPEC-14: every terminal exit path writes a v2 result (result_contract=2,
#          verdict, disposition, reason)
# SPEC-15: manifest provides block carries result_contract: 2
# SPEC-16: plugin.sh resolves deploy_result from ZBUILD_STAGE_INPUTS — no
#          hardcoded $artifacts_dir/deploy-result.json path construction
# SPEC-17: failed health probe causes validate_agent_run to return non-zero
#          (fail-closed invariant preserved under v2)
# SPEC-18: all non-zero exits use rc=1 (no exit path returns rc=2 or higher)
# SPEC-19: manifest valid_verdicts=[healthy,error]; test covers both
# SPEC-20: manifest has no config.router block; manifest_router_knob returns ""
# SPEC-21: dry-run writes result_contract=2, verdict=healthy, disposition=complete,
#          reason present, data={}; schema_version absent
# SPEC-22: manifest outputs validate_result with primary: true
# SPEC-23: manifest provides.role declares validate_agent
# SPEC-24: manifest provides.events declares exactly validate.input.missing
#          and validate.probe.failed
# SPEC-25: manifest hooks block declares only run (no cleanup hook)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: validate agent (kind:agent, ADR-018 P1, issues #757 #1845)"

setup_test_env "plugin-validate"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
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
_MANIFEST="$REPO_ROOT/plugins/agent/validate/manifest.yaml"

# Source the validate agent plugin
# shellcheck source=../../../../plugins/agent/validate/plugin.sh
source "$PLUGIN_FILE"

# Source manifest-router-budget.sh for manifest_router_knob (SPEC-20)
# shellcheck source=../../../../core/plugin-registry/manifest-router-budget.sh
source "$REPO_ROOT/core/plugin-registry/manifest-router-budget.sh"

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
# Side effects: sets ZBUILD_STAGE_INPUTS (stage-inputs.json pointing to
# deploy-result.json in the artifacts dir) and ZBUILD_ARTIFACT_DIR, so both
# v1 and v2 implementations find the expected paths consistently.
_make_state() {
    local dir="$1"
    mkdir -p "$dir/artifacts"
    printf '{"issue":"$_ZB_ID","run_id":"%s"}\n' "$ZBUILD_RUN_ID" > "$dir/state.json"
    jq -n --arg p "$dir/artifacts/deploy-result.json" \
        '{"inputs":{"deploy_result":$p}}' > "$dir/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$dir/stage-inputs.json"
    export ZBUILD_ARTIFACT_DIR="$dir/artifacts"
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

ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$_sf9"
_v9="$(jq -r '.verdict' "$_run9/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "dry-run writes verdict=healthy" "healthy" "$_v9"

# ---------------------------------------------------------------------------
# SPEC-10: missing deploy-result.json → validate_agent_run rc!=0
# ---------------------------------------------------------------------------
_run10="$TEST_TEMP_DIR/run10"
_sf10="$(_make_state "$_run10")"
# Do NOT create deploy-result.json

_rc10=0
_validate_agent_run_inner "$_sf10" || _rc10=$?
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

_MOCK_HC_RC=0  # probe succeeds
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf11"
_v11="$(jq -r '.verdict' "$_run11/artifacts/validate-result.json" 2>/dev/null || echo MISSING)"
assert_eq "healthy probe → verdict=healthy" "healthy" "$_v11"

# ---------------------------------------------------------------------------
# SPEC-12: failed health probe (rc!=0) → verdict=error in validate-result.json
# ---------------------------------------------------------------------------
_run12="$TEST_TEMP_DIR/run12"
_sf12="$(_make_state "$_run12")"
printf '{"schema_version":1,"verdict":"deployed"}\n' \
    > "$_run12/artifacts/deploy-result.json"

_MOCK_HC_RC=1  # probe fails
_rc12=0
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_sf12" || _rc12=$?
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
# v2 contract acceptance assertions (issue #1845)
# ===========================================================================

# ─── v2 result key helper ────────────────────────────────────────────────────
# Assert all four mandatory v2 keys are present and result_contract==2.
_v2_keys_ok() {
    local lbl="$1" f="$2"
    local _rc _vd _dp _rs
    _rc="$(jq -r '.result_contract // empty' "$f" 2>/dev/null || true)"
    _vd="$(jq -r '.verdict // empty' "$f" 2>/dev/null || true)"
    _dp="$(jq -r '.disposition // empty' "$f" 2>/dev/null || true)"
    _rs="$(jq -r '.reason // ""' "$f" 2>/dev/null || true)"
    assert_eq "$lbl result_contract=2" "2" "$_rc"
    if [[ -n "$_vd" ]]; then
        assert_pass "$lbl verdict key present"
    else
        assert_fail "$lbl verdict key must be present" "absent"
    fi
    if [[ -n "$_dp" ]]; then
        assert_pass "$lbl disposition key present"
    else
        assert_fail "$lbl disposition key must be present" "absent"
    fi
    if [[ -n "$_rs" ]]; then
        assert_pass "$lbl reason key present and non-empty"
    else
        assert_fail "$lbl reason key must be present and non-empty" "absent or empty"
    fi
}

# ─── v2 run setup helper ─────────────────────────────────────────────────────
# Create a run dir, optionally write deploy-result.json, set ZBUILD_STAGE_INPUTS
# and ZBUILD_ARTIFACT_DIR, create a minimal state.json. Prints the run dir.
_v2_run() {
    local name="$1" make_dr="${2:-1}"
    local dir="$TEST_TEMP_DIR/$name"
    mkdir -p "$dir/artifacts"
    local dr="$dir/deploy-result.json"
    [[ "$make_dr" == "1" ]] && printf '{"verdict":"deployed"}\n' > "$dr"
    jq -n --arg p "$dr" '{"inputs":{"deploy_result":$p}}' > "$dir/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$dir/stage-inputs.json"
    export ZBUILD_ARTIFACT_DIR="$dir/artifacts"
    printf '{"run_id":"%s"}\n' "$ZBUILD_RUN_ID" > "$dir/state.json"
    printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# SPEC-15: manifest provides block carries result_contract: 2
# ---------------------------------------------------------------------------
_s15_provides="$(awk '/^provides:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'result_contract:.*2' <<< "$_s15_provides"; then
    assert_pass "[SPEC-15] manifest provides block carries result_contract: 2"
else
    assert_fail "[SPEC-15] manifest provides block must carry result_contract: 2" \
        "${_s15_provides:-absent}"
fi

# ---------------------------------------------------------------------------
# SPEC-16: plugin.sh resolves deploy_result from ZBUILD_STAGE_INPUTS — no
#          hardcoded $artifacts_dir/deploy-result.json path construction
# ---------------------------------------------------------------------------
if grep -q 'artifacts_dir/deploy-result\.json' "$PLUGIN_FILE"; then
    assert_fail "[SPEC-16] plugin.sh must not have hardcoded \$artifacts_dir/deploy-result.json" \
        "found hardcoded path in plugin.sh"
else
    assert_pass "[SPEC-16] plugin.sh has no hardcoded \$artifacts_dir/deploy-result.json"
fi

if grep -q 'ZBUILD_STAGE_INPUTS' "$PLUGIN_FILE"; then
    assert_pass "[SPEC-16] plugin.sh references ZBUILD_STAGE_INPUTS"
else
    assert_fail "[SPEC-16] plugin.sh must reference ZBUILD_STAGE_INPUTS for input resolution" \
        "ZBUILD_STAGE_INPUTS not found in plugin.sh"
fi
if grep -q '\.inputs\.deploy_result' "$PLUGIN_FILE"; then
    assert_pass "[SPEC-16] plugin.sh uses jq .inputs.deploy_result for input resolution"
else
    assert_fail "[SPEC-16] plugin.sh must resolve deploy_result via jq .inputs.deploy_result" \
        ".inputs.deploy_result not found in plugin.sh"
fi

# ---------------------------------------------------------------------------
# SPEC-19: manifest valid_verdicts declares exactly [healthy, error];
#          test suite covers both via passing assertions
# ---------------------------------------------------------------------------
_s19_section="$(awk '/valid_verdicts:/{f=1;next} f && /^[[:space:]]*-/{print;next} f{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'healthy' <<< "$_s19_section" && grep -q 'error' <<< "$_s19_section"; then
    assert_pass "[SPEC-19] manifest config.valid_verdicts declares healthy and error"
else
    assert_fail "[SPEC-19] manifest config.valid_verdicts must declare healthy and error" \
        "${_s19_section:-absent}"
fi
_s19_count="$(grep -c '^[[:space:]]*-' <<< "$_s19_section" 2>/dev/null || printf '0')"
assert_eq "[SPEC-19] manifest config.valid_verdicts declares exactly 2 verdicts" "2" "$_s19_count"

# SPEC-19 healthy coverage: a passing assertion with verdict=healthy
_run19h="$(_v2_run run19h 1)"
printf '{"run_id":"test"}\n' > "$_run19h/state.json"
_MOCK_HC_RC=0
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_run19h/state.json"
_s19h_v="$(jq -r '.verdict // empty' "$_run19h/artifacts/validate-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-19] healthy probe → verdict=healthy (covering healthy verdict)" \
    "healthy" "$_s19h_v"

# SPEC-19 error coverage: a passing assertion with verdict=error
_run19e="$(_v2_run run19e 1)"
printf '{"run_id":"test"}\n' > "$_run19e/state.json"
_MOCK_HC_RC=1
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_run19e/state.json" || true
_s19e_v="$(jq -r '.verdict // empty' "$_run19e/artifacts/validate-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-19] failed probe → verdict=error (covering error verdict)" \
    "error" "$_s19e_v"
_MOCK_HC_RC=0

# ---------------------------------------------------------------------------
# SPEC-20: manifest has no config.router block — manifest_router_knob returns
#          empty string for timeout_s and max_turns (ADR-017)
# ---------------------------------------------------------------------------
_s20_timeout="$(manifest_router_knob "$_MANIFEST" timeout_s)"
_s20_maxturns="$(manifest_router_knob "$_MANIFEST" max_turns)"
assert_eq "[SPEC-20] manifest_router_knob timeout_s returns empty (no config.router)" \
    "" "$_s20_timeout"
assert_eq "[SPEC-20] manifest_router_knob max_turns returns empty (no config.router)" \
    "" "$_s20_maxturns"

# ---------------------------------------------------------------------------
# SPEC-22: manifest outputs array declares validate_result with primary: true
# ---------------------------------------------------------------------------
_s22_stanza="$(awk \
    '/id: validate_result/{f=1} f{print} f && /^[[:space:]]*-[[:space:]]*id:/ && !/validate_result/{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'primary: true' <<< "$_s22_stanza"; then
    assert_pass "[SPEC-22] manifest outputs validate_result declares primary: true"
else
    assert_fail "[SPEC-22] manifest outputs validate_result must declare primary: true" \
        "${_s22_stanza:-absent}"
fi

# ---------------------------------------------------------------------------
# SPEC-23: manifest provides.role declares validate_agent (#1704)
# ---------------------------------------------------------------------------
_s23_provides="$(awk '/^provides:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'role:[[:space:]]*validate_agent' <<< "$_s23_provides"; then
    assert_pass "[SPEC-23] manifest provides.role declares validate_agent"
else
    assert_fail "[SPEC-23] manifest provides.role must declare validate_agent under provides: block" \
        "${_s23_provides:-absent}"
fi

# ---------------------------------------------------------------------------
# SPEC-24: manifest provides.events declares exactly validate.input.missing
#          and validate.probe.failed (#1717)
# ---------------------------------------------------------------------------
_s24_events="$(awk \
    '/events:/{f=1;next} f && /^[[:space:]]*-/{print;next} f && /^[^[:space:]-]/{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'validate\.input\.missing' <<< "$_s24_events" && \
   grep -q 'validate\.probe\.failed' <<< "$_s24_events"; then
    assert_pass "[SPEC-24] manifest provides.events declares validate.input.missing and validate.probe.failed"
else
    assert_fail "[SPEC-24] manifest provides.events must declare both required events" \
        "${_s24_events:-absent}"
fi
_s24_count="$(grep -c 'validate\.' <<< "$_s24_events" 2>/dev/null || printf '0')"
assert_eq "[SPEC-24] manifest provides.events declares exactly 2 events" "2" "$_s24_count"
_s24_total="$(grep -c '^[[:space:]]*-' <<< "$_s24_events" 2>/dev/null || printf '0')"
assert_eq "[SPEC-24] manifest provides.events total list length is exactly 2" "2" "$_s24_total"

# ---------------------------------------------------------------------------
# SPEC-25: manifest hooks block declares only run — no cleanup hook (#1829)
# ---------------------------------------------------------------------------
_s25_hooks="$(awk '/^hooks:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'run:' <<< "$_s25_hooks"; then
    assert_pass "[SPEC-25] manifest hooks block declares run hook"
else
    assert_fail "[SPEC-25] manifest hooks block must declare run hook" "absent"
fi
if grep -q 'cleanup:' <<< "$_s25_hooks"; then
    assert_fail "[SPEC-25] manifest hooks block must not declare cleanup hook (plugin holds no resources)" \
        "cleanup hook found"
else
    assert_pass "[SPEC-25] manifest hooks block has no cleanup hook"
fi
_s25_hook_count="$(grep -cE '^[[:space:]]+[a-z_]+:' <<< "$_s25_hooks" 2>/dev/null || printf '0')"
assert_eq "[SPEC-25] manifest hooks block declares exactly one hook (run only)" "1" "$_s25_hook_count"

# ---------------------------------------------------------------------------
# SPEC-21: dry-run writes result_contract=2, verdict=healthy, disposition=complete,
#          reason present, data={}; schema_version key absent
# ---------------------------------------------------------------------------
_run21="$(_v2_run run21 1)"
printf '{"run_id":"test"}\n' > "$_run21/state.json"
ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$_run21/state.json"
_s21_out="$_run21/artifacts/validate-result.json"

assert_eq "[SPEC-21] dry-run writes result_contract=2" \
    "2" "$(jq -r '.result_contract // empty' "$_s21_out" 2>/dev/null || printf MISSING)"
assert_eq "[SPEC-21] dry-run writes verdict=healthy" \
    "healthy" "$(jq -r '.verdict // empty' "$_s21_out" 2>/dev/null || printf MISSING)"
assert_eq "[SPEC-21] dry-run writes disposition=complete" \
    "complete" "$(jq -r '.disposition // empty' "$_s21_out" 2>/dev/null || printf MISSING)"
_s21_reason="$(jq -r '.reason // ""' "$_s21_out" 2>/dev/null || true)"
if [[ -n "$_s21_reason" ]]; then
    assert_pass "[SPEC-21] dry-run writes non-empty reason"
else
    assert_fail "[SPEC-21] dry-run result must have non-empty reason" "empty or absent"
fi
_s21_data="$(jq -c '.data // "ABSENT"' "$_s21_out" 2>/dev/null || printf MISSING)"
assert_eq "[SPEC-21] dry-run writes data={}" "{}" "$_s21_data"
_s21_sv="$(jq -r '.schema_version // "ABSENT"' "$_s21_out" 2>/dev/null || printf MISSING)"
assert_eq "[SPEC-21] dry-run result must not have schema_version key" "ABSENT" "$_s21_sv"

# ---------------------------------------------------------------------------
# SPEC-14: every terminal exit path of _validate_agent_run_inner writes a
#          result file containing all four mandatory v2 keys
# ---------------------------------------------------------------------------

# Path 1 — missing deploy-result (broken disposition)
_run14a="$(_v2_run run14a 0)"
printf '{"run_id":"test"}\n' > "$_run14a/state.json"
_validate_agent_run_inner "$_run14a/state.json" || true
_v2_keys_ok "[SPEC-14] missing-input exit path:" "$_run14a/artifacts/validate-result.json"

# Path 2 — dry-run (complete disposition)
_run14b="$(_v2_run run14b 1)"
printf '{"run_id":"test"}\n' > "$_run14b/state.json"
ZBUILD_DRY_RUN=1 _validate_agent_run_inner "$_run14b/state.json"
_v2_keys_ok "[SPEC-14] dry-run exit path:" "$_run14b/artifacts/validate-result.json"

# Path 3 — successful health probe (complete disposition)
_run14c="$(_v2_run run14c 1)"
printf '{"run_id":"test"}\n' > "$_run14c/state.json"
_MOCK_HC_RC=0
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_run14c/state.json"
_v2_keys_ok "[SPEC-14] healthy-probe exit path:" "$_run14c/artifacts/validate-result.json"

# Path 4 — failed health probe (complete disposition, non-zero rc)
_run14d="$(_v2_run run14d 1)"
printf '{"run_id":"test"}\n' > "$_run14d/state.json"
_MOCK_HC_RC=1
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_run14d/state.json" || true
_v2_keys_ok "[SPEC-14] failed-probe exit path:" "$_run14d/artifacts/validate-result.json"
_MOCK_HC_RC=0

# Path 5 — health-check plugin file absent (broken disposition)
_run14e="$(_v2_run run14e 1)"
printf '{"run_id":"test"}\n' > "$_run14e/state.json"
_saved_vr="$_VALIDATE_ROOT"
_VALIDATE_ROOT="$TEST_TEMP_DIR/no-hc-plugins"
mkdir -p "$TEST_TEMP_DIR/no-hc-plugins"
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_run14e/state.json" || true
_v2_keys_ok "[SPEC-14] missing-hc-plugin exit path:" "$_run14e/artifacts/validate-result.json"
_VALIDATE_ROOT="$_saved_vr"

# ---------------------------------------------------------------------------
# SPEC-17: a failed health probe causes validate_agent_run to return non-zero
#          (the #757 fail-closed invariant preserved under v2)
# ---------------------------------------------------------------------------
_run17="$(_v2_run run17 1)"
_MOCK_HC_RC=1
_rc17=0
ZBUILD_DRY_RUN=0 validate_agent_run "run" "$_run17/state.json" || _rc17=$?
assert_gt "[SPEC-17] failed health probe causes validate_agent_run to return non-zero" \
    "$_rc17" "0"
_MOCK_HC_RC=0

# ---------------------------------------------------------------------------
# SPEC-18: all non-zero exits from plugin.sh use rc=1 — no exit path returns
#          rc=2 or higher
# ---------------------------------------------------------------------------

# Missing deploy-result → must be rc=1 (was rc=2 in v1)
_run18a="$(_v2_run run18a 0)"
printf '{"run_id":"test"}\n' > "$_run18a/state.json"
_rc18a=0
_validate_agent_run_inner "$_run18a/state.json" || _rc18a=$?
assert_eq "[SPEC-18] missing deploy-result exits with rc=1 (not rc=2)" "1" "$_rc18a"

# Failed probe with rc=5 → must be clamped to rc=1 (was $hc_rc in v1)
_run18b="$(_v2_run run18b 1)"
printf '{"run_id":"test"}\n' > "$_run18b/state.json"
_MOCK_HC_RC=5
_rc18b=0
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_run18b/state.json" || _rc18b=$?
assert_eq "[SPEC-18] failed probe with rc=5 exits with rc=1 (clamped, not rc=5)" "1" "$_rc18b"
_MOCK_HC_RC=0

# Missing hc-plugin → must be rc=1 (was rc=2 in v1)
_run18e="$(_v2_run run18e 1)"
printf '{"run_id":"test"}\n' > "$_run18e/state.json"
_saved_vr2="$_VALIDATE_ROOT"
_VALIDATE_ROOT="$TEST_TEMP_DIR/no-hc-plugins"
_rc18e=0
ZBUILD_DRY_RUN=0 _validate_agent_run_inner "$_run18e/state.json" || _rc18e=$?
assert_eq "[SPEC-18] missing hc-plugin exits with rc=1 (not rc=2)" "1" "$_rc18e"
_VALIDATE_ROOT="$_saved_vr2"

# Universal static check: no non-comment code path in plugin.sh exits with rc>=2
_s18_nc="$(grep -v '^[[:space:]]*#' "$PLUGIN_FILE" 2>/dev/null || true)"
_s18_high="$(grep -E '\b(exit|return)[[:space:]]+[2-9]' <<< "$_s18_nc" 2>/dev/null || true)"
if [[ -z "$_s18_high" ]]; then
    assert_pass "[SPEC-18] plugin.sh has no non-comment exit/return with rc>=2"
else
    assert_fail "[SPEC-18] plugin.sh must not exit/return with rc>=2 on any code path" \
        "$_s18_high"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
