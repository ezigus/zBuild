#!/usr/bin/env bash
# Tests: plugins/agent/deploy — deploy stage agent unit tests (issues #757, #1846)
#
# Covers: SPEC-1..24 (deploy plugin contract v2 migration)
# SPEC-1  [#1846/SPEC-1]:  deploy plugin exists with deploy_agent_run function
# SPEC-2  [#1846/SPEC-2]:  ZBUILD_DRY_RUN=1 writes deploy-result.json verdict=deployed (ZBUILD_STAGE_INPUTS dispatch)
# SPEC-3  [#1846/SPEC-3]:  missing pr_url input → rc!=0 and verdict=error
# SPEC-4  [#1846/SPEC-4]:  gate verdict=fail → verdict=skipped (fail-closed allowlist)
# SPEC-5  [#1846/SPEC-5]:  plugin.sh has "Role: deploy_agent" preamble comment
# SPEC-6  [#1846/SPEC-6]:  no route_to_model call in non-comment code
# SPEC-7  [#1846/SPEC-7]:  dry-run deploy-result.json carries result_contract=2 (not schema_version=1)
# SPEC-8  [#1846/SPEC-8]:  missing gate (non-dry-run) → fail-closed rc=1 (not rc=2)
# SPEC-9  [#1846/SPEC-9]:  manifest provides block declares result_contract: 2
# SPEC-10 [#1846/SPEC-10]: every terminal exit path writes v2 envelope
# SPEC-11 [#1846/SPEC-11]: plugin.sh derives output path from ZBUILD_ARTIFACT_DIR; no state_file-derived path
# SPEC-12 [#1846/SPEC-12]: pr_url and gate_aggregator_result resolved via ZBUILD_STAGE_INPUTS
# SPEC-13 [#1846/SPEC-13]: all error exit paths return rc=1; no exit path returns rc=2 or higher
# SPEC-14 [#1846/SPEC-14]: all three valid verdicts exercised with v2-shaped result
# SPEC-15 [#1846/SPEC-15]: manifest has no config.router block; manifest_router_knob returns empty
# SPEC-16 [#1846/SPEC-16]: manifest outputs.deploy_result retains primary: true
# SPEC-17 [#1846/SPEC-17]: manifest provides.role = deploy_agent; provides.events = exactly 6 events (4 + deploy.input.refused, deploy.result.unwritable)
# SPEC-18 [#1846/SPEC-18]: manifest hooks block declares only run; no cleanup entry
# SPEC-19 [#1846/SPEC-19]: dry-run carries verdict=deployed, disposition=complete, reason present
# SPEC-20 [#1846/SPEC-20]: deploy-release fails → ITS disposition reaches the engine (deploy-release-interface-test.sh)
# SPEC-21 [#1846/SPEC-21]: deploy-release plugin file absent → disposition=broken
# SPEC-22 [#1846/SPEC-22]: manifest config.valid_verdicts lists exactly deployed, error, skipped
# SPEC-24 [#1846/SPEC-24]: manifest carries router-budget-absence comment ("router budgets: none" + ADR-037 §3)
#
# The run paths through the REAL deploy-release (only git/gh faked) live in
# deploy-release-interface-test.sh; shared fixtures in deploy-test-lib.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: deploy agent (kind:agent, ADR-018 P1, issues #757 #1846)"

setup_test_env "plugin-deploy"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export ZBUILD_RUN_ID="deploy-test-$$"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_ISSUE="$_ZB_ID"

PLUGIN_FILE="$REPO_ROOT/plugins/agent/deploy/plugin.sh"
_MANIFEST="$REPO_ROOT/plugins/agent/deploy/manifest.yaml"

# Source the deploy agent plugin
# shellcheck source=../../../../plugins/agent/deploy/plugin.sh
source "$PLUGIN_FILE"

# Source manifest-router-budget.sh for manifest_router_knob (SPEC-15)
# shellcheck source=../../../../core/plugin-registry/manifest-router-budget.sh
source "$REPO_ROOT/core/plugin-registry/manifest-router-budget.sh"

# shellcheck source=deploy-test-lib.sh
source "$SCRIPT_DIR/deploy-test-lib.sh"

# ===========================================================================
# Guard assertions — static checks on the plugin and manifest files
# ===========================================================================

# ---------------------------------------------------------------------------
# SPEC-1 [#1846/SPEC-1]: deploy plugin.sh exists and deploy_agent_run is
#                        defined after source
# ---------------------------------------------------------------------------
if [[ -f "$PLUGIN_FILE" ]]; then
    assert_pass "[#1846/SPEC-1] deploy plugin.sh exists at expected path"
else
    assert_fail "[#1846/SPEC-1] deploy plugin.sh exists at expected path" \
        "not found: $PLUGIN_FILE"
fi

if type deploy_agent_run >/dev/null 2>&1; then
    assert_pass "[#1846/SPEC-1] deploy_agent_run function defined after source"
else
    assert_fail "[#1846/SPEC-1] deploy_agent_run function defined after source" \
        "function not found"
fi

# ---------------------------------------------------------------------------
# SPEC-5 [#1846/SPEC-5]: plugin.sh has "Role: deploy_agent" preamble comment
# ---------------------------------------------------------------------------
_s5_preamble="$(head -20 "$PLUGIN_FILE" 2>/dev/null || true)"
if grep -qE '^[[:space:]]*#[[:space:]]*Role:[[:space:]]*deploy_agent' <<< "$_s5_preamble"; then
    assert_pass "[#1846/SPEC-5] deploy plugin.sh has '# Role: deploy_agent' as a comment in preamble (first 20 lines)"
else
    assert_fail "[#1846/SPEC-5] deploy plugin.sh must have '# Role: deploy_agent' as a comment line in preamble" \
        "not found as comment line in first 20 lines of $PLUGIN_FILE"
fi

# ---------------------------------------------------------------------------
# SPEC-6 [#1846/SPEC-6]: no route_to_model call in non-comment code
# ---------------------------------------------------------------------------
_code6="$(grep -v '^[[:space:]]*#' "$PLUGIN_FILE" || true)"
if grep -q "route_to_model" <<< "$_code6"; then
    assert_fail "[#1846/SPEC-6] deploy plugin must not call route_to_model in non-comment code" \
        "route_to_model found in executable code in $PLUGIN_FILE"
else
    assert_pass "[#1846/SPEC-6] deploy plugin has no route_to_model call in non-comment code"
fi

# ---------------------------------------------------------------------------
# SPEC-9 [#1846/SPEC-9]: manifest provides block declares result_contract: 2
# ---------------------------------------------------------------------------
_s9_provides="$(awk '/^provides:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'result_contract:.*2' <<< "$_s9_provides"; then
    assert_pass "[#1846/SPEC-9] manifest provides block declares result_contract: 2"
else
    assert_fail "[#1846/SPEC-9] manifest provides block must declare result_contract: 2" \
        "${_s9_provides:-absent}"
fi

# ---------------------------------------------------------------------------
# SPEC-11 [#1846/SPEC-11]: plugin.sh derives output path from ZBUILD_ARTIFACT_DIR;
#                          no state_file-derived path (no state_dir/artifacts pattern)
# ---------------------------------------------------------------------------
if grep -qE 'state_dir[/"]*/artifacts|dirname.*state_file.*/artifacts' "$PLUGIN_FILE"; then
    assert_fail "[#1846/SPEC-11] plugin.sh must not derive output path from state_file/state_dir" \
        "state_file-derived artifact path found in $PLUGIN_FILE"
else
    assert_pass "[#1846/SPEC-11] plugin.sh has no state_file-derived artifact path"
fi

if grep -q 'ZBUILD_ARTIFACT_DIR' "$PLUGIN_FILE"; then
    assert_pass "[#1846/SPEC-11] plugin.sh references ZBUILD_ARTIFACT_DIR for output path"
else
    assert_fail "[#1846/SPEC-11] plugin.sh must reference ZBUILD_ARTIFACT_DIR for output path" \
        "ZBUILD_ARTIFACT_DIR not found in $PLUGIN_FILE"
fi

# ---------------------------------------------------------------------------
# SPEC-12 [#1846/SPEC-12]: pr_url and gate_aggregator_result resolved via
#                          ZBUILD_STAGE_INPUTS; plugin.sh constructs no
#                          pr-url.txt or gate-aggregator-result.json path
# ---------------------------------------------------------------------------
if grep -qE "pr-url\.txt|gate-aggregator-result\.json" "$PLUGIN_FILE"; then
    assert_fail "[#1846/SPEC-12] plugin.sh must not hardcode pr-url.txt or gate-aggregator-result.json paths" \
        "hardcoded input filename found in $PLUGIN_FILE"
else
    assert_pass "[#1846/SPEC-12] plugin.sh has no hardcoded pr-url.txt or gate-aggregator-result.json path"
fi

if grep -q 'ZBUILD_STAGE_INPUTS' "$PLUGIN_FILE"; then
    assert_pass "[#1846/SPEC-12] plugin.sh references ZBUILD_STAGE_INPUTS for input resolution"
else
    assert_fail "[#1846/SPEC-12] plugin.sh must reference ZBUILD_STAGE_INPUTS for input resolution" \
        "ZBUILD_STAGE_INPUTS not found in $PLUGIN_FILE"
fi

# ---------------------------------------------------------------------------
# SPEC-13 [#1846/SPEC-13]: static check — no non-comment code exits with rc>=2
# ---------------------------------------------------------------------------
_s13_nc="$(grep -v '^[[:space:]]*#' "$PLUGIN_FILE" 2>/dev/null || true)"
_s13_high="$(grep -E '\b(exit|return)[[:space:]]+[2-9]' <<< "$_s13_nc" 2>/dev/null || true)"
if [[ -z "$_s13_high" ]]; then
    assert_pass "[#1846/SPEC-13] plugin.sh has no non-comment exit/return with rc>=2"
else
    assert_fail "[#1846/SPEC-13] plugin.sh must not exit/return with rc>=2 on any code path" \
        "$_s13_high"
fi

# ---------------------------------------------------------------------------
# SPEC-15 [#1846/SPEC-15]: manifest has no config.router block;
#                          manifest_router_knob returns empty for timeout_s
#                          and max_turns
# ---------------------------------------------------------------------------
_s15_timeout="$(manifest_router_knob "$_MANIFEST" timeout_s)"
_s15_maxturns="$(manifest_router_knob "$_MANIFEST" max_turns)"
assert_eq "[#1846/SPEC-15] manifest_router_knob timeout_s returns empty (no config.router)" \
    "" "$_s15_timeout"
assert_eq "[#1846/SPEC-15] manifest_router_knob max_turns returns empty (no config.router)" \
    "" "$_s15_maxturns"

# ---------------------------------------------------------------------------
# SPEC-16 [#1846/SPEC-16]: manifest outputs.deploy_result retains primary: true
# ---------------------------------------------------------------------------
_s16_stanza="$(awk \
    '/id: deploy_result/{f=1} f{print} f && /^[[:space:]]*-[[:space:]]*id:/ && !/deploy_result/{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'primary: true' <<< "$_s16_stanza"; then
    assert_pass "[#1846/SPEC-16] manifest outputs.deploy_result declares primary: true"
else
    assert_fail "[#1846/SPEC-16] manifest outputs.deploy_result must declare primary: true" \
        "${_s16_stanza:-absent}"
fi

# ---------------------------------------------------------------------------
# SPEC-17 [#1846/SPEC-17]: manifest provides.role = deploy_agent;
#                          provides.events = exactly the declared events
#                          (six since review #2219: deploy.input.refused (R7) and
#                          deploy.result.unwritable (R6) joined the original four)
# ---------------------------------------------------------------------------
_s17_provides="$(awk '/^provides:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'role:[[:space:]]*deploy_agent' <<< "$_s17_provides"; then
    assert_pass "[#1846/SPEC-17] manifest provides.role = deploy_agent"
else
    assert_fail "[#1846/SPEC-17] manifest provides.role must be deploy_agent" \
        "${_s17_provides:-absent}"
fi

_s17_events="$(awk \
    '/events:/{f=1;next} f && /^[[:space:]]*-/{print;next} f && /^[^[:space:]-]/{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
for _ev in "deploy.gate.missing" "deploy.input.missing" "deploy.input.refused" "deploy.result.unwritable" "deploy.skipped" "deploy.tool.failed"; do
    if grep -q "$_ev" <<< "$_s17_events"; then
        assert_pass "[#1846/SPEC-17] manifest provides.events includes $_ev"
    else
        assert_fail "[#1846/SPEC-17] manifest provides.events must include $_ev" \
            "${_s17_events:-absent}"
    fi
done
_s17_count="$(grep -c '^[[:space:]]*-' <<< "$_s17_events" 2>/dev/null || true)"
assert_eq "[#1846/SPEC-17] manifest provides.events declares exactly 6 events" "6" "$_s17_count"

# ---------------------------------------------------------------------------
# SPEC-18 [#1846/SPEC-18]: manifest hooks block declares only run; no cleanup
# ---------------------------------------------------------------------------
_s18_hooks="$(awk '/^hooks:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -qE 'run:[[:space:]]*deploy_agent_run' <<< "$_s18_hooks"; then
    assert_pass "[#1846/SPEC-18] manifest hooks block declares run: deploy_agent_run"
else
    assert_fail "[#1846/SPEC-18] manifest hooks block must declare run: deploy_agent_run" \
        "${_s18_hooks:-absent}"
fi
if grep -q 'cleanup:' <<< "$_s18_hooks"; then
    assert_fail "[#1846/SPEC-18] manifest hooks block must not declare cleanup hook" \
        "cleanup entry found"
else
    assert_pass "[#1846/SPEC-18] manifest hooks block has no cleanup hook"
fi
_s18_count="$(grep -cE '^[[:space:]]+[a-z_]+:' <<< "$_s18_hooks" 2>/dev/null || printf '0')"
assert_eq "[#1846/SPEC-18] manifest hooks block declares exactly one hook (run only)" "1" "$_s18_count"

# ---------------------------------------------------------------------------
# SPEC-22 [#1846/SPEC-22]: manifest config.valid_verdicts lists exactly
#                          deployed, error, skipped
# ---------------------------------------------------------------------------
_s22_section="$(awk '/valid_verdicts:/{f=1;next} f && /^[[:space:]]*-/{print;next} f{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
for _vv in "deployed" "error" "skipped"; do
    if grep -q "$_vv" <<< "$_s22_section"; then
        assert_pass "[#1846/SPEC-22] manifest config.valid_verdicts includes $_vv"
    else
        assert_fail "[#1846/SPEC-22] manifest config.valid_verdicts must include $_vv" \
            "${_s22_section:-absent}"
    fi
done
_s22_count="$(grep -c '^[[:space:]]*-' <<< "$_s22_section" 2>/dev/null || printf '0')"
assert_eq "[#1846/SPEC-22] manifest config.valid_verdicts declares exactly 3 verdicts" "3" "$_s22_count"

# ---------------------------------------------------------------------------
# SPEC-24 [#1846/SPEC-24]: manifest carries router-budget-absence comment
#                          with "router budgets: none" and ADR-037 §3
# ---------------------------------------------------------------------------
_s24_ctx="$(grep -B2 -A3 'router budgets: none' "$_MANIFEST" 2>/dev/null || true)"
if [[ -n "$_s24_ctx" ]]; then
    assert_pass "[#1846/SPEC-24] manifest carries 'router budgets: none' comment"
else
    assert_fail "[#1846/SPEC-24] manifest must carry 'router budgets: none' comment" \
        "not found in $_MANIFEST"
fi
if grep -q 'ADR-037' <<< "$_s24_ctx" && grep -q '§3' <<< "$_s24_ctx"; then
    assert_pass "[#1846/SPEC-24] manifest router-budget comment has 'ADR-037 §3' near 'router budgets: none'"
else
    assert_fail "[#1846/SPEC-24] manifest comment near 'router budgets: none' must reference both ADR-037 and §3" \
        "${_s24_ctx:-absent}"
fi

# ===========================================================================
# Behavioural assertions — dynamic tests via ZBUILD_STAGE_INPUTS dispatch
# ===========================================================================

# ---------------------------------------------------------------------------
# SPEC-2/7/19 [#1846/SPEC-2,7,19]: ZBUILD_DRY_RUN=1 writes deploy-result.json
#             with verdict=deployed, result_contract=2, disposition=complete,
#             reason present (full v2 envelope)
# ---------------------------------------------------------------------------
_run_dry="$TEST_TEMP_DIR/run_dry"
( _make_state "$_run_dry"
  printf 'https://github.com/test/repo/pull/42\n' > "$_run_dry/artifacts/pr-url.txt"
  ZBUILD_DRY_RUN=1 deploy_agent_run "deploy" "$_run_dry/state.json" ) >/dev/null 2>&1 || true
_dry_out="$_run_dry/artifacts/deploy-result.json"

_dry_v="$(jq -r '.verdict // empty' "$_dry_out" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-2] dry-run writes verdict=deployed" "deployed" "$_dry_v"

_dry_rc="$(jq -r '.result_contract // empty' "$_dry_out" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-7] dry-run deploy-result.json carries result_contract=2" "2" "$_dry_rc"

_dry_sv="$(jq -r '.schema_version // "ABSENT"' "$_dry_out" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-7] dry-run deploy-result.json must not carry schema_version key" \
    "ABSENT" "$_dry_sv"

assert_eq "[#1846/SPEC-19] dry-run carries verdict=deployed" "deployed" "$_dry_v"

_dry_dp="$(jq -r '.disposition // empty' "$_dry_out" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-19] dry-run carries disposition=complete" "complete" "$_dry_dp"

_dry_rs="$(jq -r '.reason // ""' "$_dry_out" 2>/dev/null || true)"
if [[ -n "$_dry_rs" ]]; then
    assert_pass "[#1846/SPEC-19] dry-run carries non-empty reason"
else
    assert_fail "[#1846/SPEC-19] dry-run result must have non-empty reason" "absent or empty"
fi

_v2_keys_ok "[#1846/SPEC-10] dry-run exit path:" "$_dry_out"

# ---------------------------------------------------------------------------
# SPEC-3 [#1846/SPEC-3]: missing pr_url input → rc!=0 and verdict=error
#        (ZBUILD_STAGE_INPUTS index exists but pr_url file is absent)
# ---------------------------------------------------------------------------
_run_nopr="$TEST_TEMP_DIR/run_nopr"
# Do NOT create pr-url.txt — the path in the index points to a non-existent file
_rc3=0
( _make_state "$_run_nopr"; deploy_agent_run "deploy" "$_run_nopr/state.json" ) >/dev/null 2>&1 || _rc3=$?
assert_gt "[#1846/SPEC-3] missing pr_url input → rc != 0" "$_rc3" "0"

_v3="$(jq -r '.verdict // empty' "$_run_nopr/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-3] missing pr_url → verdict=error" "error" "$_v3"

_v2_keys_ok "[#1846/SPEC-10] missing-pr_url exit path:" \
    "$_run_nopr/artifacts/deploy-result.json"

assert_eq "[#1846/SPEC-13] missing pr_url → rc=1 (not rc=2+)" "1" "$_rc3"

# ---------------------------------------------------------------------------
# SPEC-4 [#1846/SPEC-4]: gate verdict=fail → verdict=skipped (fail-closed)
#        gate verdict=route_design (non-pass) → verdict=skipped (allowlist)
# ---------------------------------------------------------------------------
_run_gatefail="$TEST_TEMP_DIR/run_gatefail"
_deploy_case "$_run_gatefail" fail >/dev/null
_v4="$(jq -r '.verdict // empty' "$_run_gatefail/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-4] gate verdict=fail → deploy-result verdict=skipped" "skipped" "$_v4"

_v2_keys_ok "[#1846/SPEC-10] gate-fail exit path:" \
    "$_run_gatefail/artifacts/deploy-result.json"

# Fail-closed allowlist: non-pass verdict also skips
_run_routedesign="$TEST_TEMP_DIR/run_routedesign"
_deploy_case "$_run_routedesign" route_design >/dev/null
_v4b="$(jq -r '.verdict // empty' "$_run_routedesign/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-4] gate verdict=route_design (non-pass) → skipped (allowlist)" "skipped" "$_v4b"

# ---------------------------------------------------------------------------
# SPEC-8 [#1846/SPEC-8]: missing gate (non-dry-run) → fail-closed rc=1 (not rc=2)
#        and verdict=error
# ---------------------------------------------------------------------------
_run_nogate="$TEST_TEMP_DIR/run_nogate"
# Do NOT create gate-aggregator-result.json
_rc8="$(_deploy_case "$_run_nogate" -)"
assert_eq "[#1846/SPEC-8] missing gate (non-dry-run) → fail-closed rc=1 (not rc=2)" "1" "$_rc8"

_v8="$(jq -r '.verdict // empty' "$_run_nogate/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-8] missing gate → verdict=error" "error" "$_v8"

_v2_keys_ok "[#1846/SPEC-10] missing-gate exit path:" \
    "$_run_nogate/artifacts/deploy-result.json"

assert_eq "[#1846/SPEC-13] missing gate → rc=1 (not rc=2+)" "1" "$_rc8"

# ---------------------------------------------------------------------------
# SPEC-21 [#1846/SPEC-21]: deploy-release plugin file absent →
#                          deploy-result.json disposition=broken
# ---------------------------------------------------------------------------
_run_drabsent="$TEST_TEMP_DIR/run_drabsent"
mkdir -p "$TEST_TEMP_DIR/no-deploy-release"
_rc21="$(_deploy_case "$_run_drabsent" pass _DEPLOY_ROOT="$TEST_TEMP_DIR/no-deploy-release")"

_dp21="$(jq -r '.disposition // empty' "$_run_drabsent/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-21] deploy-release absent → disposition=broken" \
    "broken" "$_dp21"

_v2_keys_ok "[#1846/SPEC-10] deploy-release-absent exit path:" \
    "$_run_drabsent/artifacts/deploy-result.json"

assert_eq "[#1846/SPEC-13] deploy-release absent → rc=1" "1" "$_rc21"

# ---------------------------------------------------------------------------
# SPEC-14 [#1846/SPEC-14]: all three verdicts exercised with v2-shaped result
#         deployed → covered above (dry-run + success path)
#         error    → covered above (missing pr_url + missing gate)
#         skipped  → covered above (gate=fail)
# Apply _v2_keys_ok to each to confirm all three are v2-shaped.
# ---------------------------------------------------------------------------
_v2_keys_ok "[#1846/SPEC-14] verdict=deployed (dry-run):" "$_dry_out"
_v2_keys_ok "[#1846/SPEC-14] verdict=error (missing pr_url):" \
    "$_run_nopr/artifacts/deploy-result.json"
_v2_keys_ok "[#1846/SPEC-14] verdict=skipped (gate=fail):" \
    "$_run_gatefail/artifacts/deploy-result.json"

_v14_d="$(jq -r '.verdict' "$_dry_out" 2>/dev/null || printf MISSING)"
_v14_e="$(jq -r '.verdict' "$_run_nopr/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
_v14_s="$(jq -r '.verdict' "$_run_gatefail/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-14] verdict=deployed covered" "deployed" "$_v14_d"
assert_eq "[#1846/SPEC-14] verdict=error covered" "error" "$_v14_e"
assert_eq "[#1846/SPEC-14] verdict=skipped covered" "skipped" "$_v14_s"

# ─── Cleanup ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
