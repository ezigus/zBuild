#!/usr/bin/env bash
# Tests: plugins/agent/deploy — deploy stage agent unit tests (issues #757, #1846)
#
# Covers: SPEC-1..8 (deploy plugin contract guards, issue #757)
#         SPEC-7..22 (v2 contract migration acceptance, issue #1846)
# [#1846/SPEC-1]:  deploy plugin.sh exists and deploy_agent_run is defined after source
# [#1846/SPEC-2]:  ZBUILD_DRY_RUN=1 writes deploy-result.json with verdict=deployed
# [#1846/SPEC-3]:  missing pr_url input → deploy_agent_run exits non-zero + verdict=error
# [#1846/SPEC-4]:  gate verdict=fail → deploy-result.json verdict=skipped (fail-closed allowlist)
# [#1846/SPEC-5]:  plugin.sh has "Role: deploy_agent" preamble comment
# [#1846/SPEC-6]:  no route_to_model call in non-comment code
# [#1846/SPEC-7]:  dry-run deploy-result.json carries result_contract=2 (not schema_version=1)
# [#1846/SPEC-8]:  missing gate (non-dry-run) → fail-closed returns rc=1 (not rc=2)
# [#1846/SPEC-9]:  manifest provides block declares result_contract: 2
# [#1846/SPEC-10]: every terminal exit path writes v2 envelope: result_contract=2, verdict,
#                  disposition, reason all present
# [#1846/SPEC-11]: plugin.sh derives output path from ZBUILD_ARTIFACT_DIR; no state_file path
# [#1846/SPEC-12]: pr_url and gate_aggregator_result resolved via ZBUILD_STAGE_INPUTS;
#                  no pr-url.txt or gate-aggregator-result.json path constructed in code
# [#1846/SPEC-13]: all error exit paths return rc=1; no exit path returns rc=2 or higher
# [#1846/SPEC-14]: all three valid verdicts (deployed, error, skipped) exercised with v2 result
# [#1846/SPEC-15]: manifest has no config.router block; manifest_router_knob returns empty
# [#1846/SPEC-16]: manifest outputs.deploy_result retains primary: true
# [#1846/SPEC-17]: manifest provides.role = deploy_agent; provides.events = exactly four declared
# [#1846/SPEC-18]: manifest hooks block declares only run: deploy_agent_run; no cleanup: entry
# [#1846/SPEC-19]: dry-run deploy-result.json carries verdict=deployed, disposition=complete,
#                  reason present (full v2 envelope)
# [#1846/SPEC-20]: deploy-release returns non-zero → deploy-result.json disposition=unavailable
# [#1846/SPEC-21]: deploy-release plugin file absent → deploy-result.json disposition=broken
# [#1846/SPEC-22]: manifest config.valid_verdicts lists exactly: deployed, error, skipped
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
# Sets ZBUILD_STAGE_INPUTS (the engine's input index naming pr_url and
# gate_aggregator_result) and ZBUILD_ARTIFACT_DIR. Leaves state file path in
# _MS_SF. Called in THIS shell, never as $(...): an export inside a command
# substitution never reaches the test.
_make_state() {
    local dir="$1"
    local pr_url="${2:-https://github.com/test/repo/pull/42}"
    local gate_verdict="${3:-}"      # empty = don't create gate file
    mkdir -p "$dir/artifacts" "$dir/stage-inputs"
    jq -n --arg iss "$_ZB_ID" --arg run "$ZBUILD_RUN_ID" \
        '{issue:$iss, run_id:$run}' > "$dir/state.json"
    # Write pr_url file and gate file (if requested) into a shared inputs area
    local pr_url_file="$dir/stage-inputs/pr-url.txt"
    printf '%s\n' "$pr_url" > "$pr_url_file"
    local gate_file="$dir/stage-inputs/gate-aggregator-result.json"
    if [[ -n "$gate_verdict" ]]; then
        printf '{"verdict":"%s","reason":"test"}\n' "$gate_verdict" > "$gate_file"
    fi
    # Build the ZBUILD_STAGE_INPUTS index the engine would hand the stage
    if [[ -n "$gate_verdict" ]]; then
        jq -n --arg pu "$pr_url_file" --arg gf "$gate_file" \
            '{"inputs":{"pr_url":$pu,"gate_aggregator_result":$gf}}' \
            > "$dir/stage-inputs/deploy.json"
    else
        jq -n --arg pu "$pr_url_file" \
            '{"inputs":{"pr_url":$pu}}' \
            > "$dir/stage-inputs/deploy.json"
    fi
    export ZBUILD_STAGE_INPUTS="$dir/stage-inputs/deploy.json"
    export ZBUILD_ARTIFACT_DIR="$dir/artifacts"
    _MS_SF="$dir/state.json"
}

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

# ---------------------------------------------------------------------------
# [#1846/SPEC-1]: deploy plugin.sh exists and deploy_agent_run is defined after source
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
# [#1846/SPEC-5]: plugin.sh has "Role: deploy_agent" preamble comment
# ---------------------------------------------------------------------------
if grep -q "Role: deploy_agent" "$PLUGIN_FILE"; then
    assert_pass "[#1846/SPEC-5] deploy plugin has 'Role: deploy_agent' preamble comment"
else
    assert_fail "[#1846/SPEC-5] deploy plugin has 'Role: deploy_agent' preamble comment" \
        "line not found in $PLUGIN_FILE"
fi

# ---------------------------------------------------------------------------
# [#1846/SPEC-6]: no route_to_model call in non-comment code
# ---------------------------------------------------------------------------
# Strip comment lines before checking — the plugin may mention route_to_model
# in documentation comments; we only reject actual function calls in code.
_code_lines6="$(grep -v '^[[:space:]]*#' "$PLUGIN_FILE" || true)"
if grep -q "route_to_model" <<< "$_code_lines6"; then
    assert_fail "[#1846/SPEC-6] deploy plugin must not call route_to_model (T0 no-LLM invariant)" \
        "route_to_model call found in non-comment code in $PLUGIN_FILE"
else
    assert_pass "[#1846/SPEC-6] deploy plugin has no route_to_model call in executable code"
fi

# ---------------------------------------------------------------------------
# [#1846/SPEC-11]: plugin.sh derives output path from ZBUILD_ARTIFACT_DIR;
#                  no state_file-derived path construction
# ---------------------------------------------------------------------------
# The plugin must not compute "$state_dir/artifacts" or "$state_file/.../artifacts"
_code_lines11="$(grep -v '^[[:space:]]*#' "$PLUGIN_FILE" || true)"
if grep -q 'state_dir/artifacts\|state_file.*artifacts\|dirname.*state.*artifacts' \
    <<< "$_code_lines11"; then
    assert_fail "[#1846/SPEC-11] plugin.sh must not derive output path from state_file" \
        "state_file-derived artifact path found in non-comment code"
else
    assert_pass "[#1846/SPEC-11] plugin.sh has no state_file-derived output path"
fi

if grep -q 'ZBUILD_ARTIFACT_DIR' "$PLUGIN_FILE"; then
    assert_pass "[#1846/SPEC-11] plugin.sh references ZBUILD_ARTIFACT_DIR for output path"
else
    assert_fail "[#1846/SPEC-11] plugin.sh must reference ZBUILD_ARTIFACT_DIR for output path" \
        "ZBUILD_ARTIFACT_DIR not found in plugin.sh"
fi

# ---------------------------------------------------------------------------
# [#1846/SPEC-12]: pr_url and gate_aggregator_result resolved via
#                  ZBUILD_STAGE_INPUTS; no hardcoded path construction in code
# ---------------------------------------------------------------------------
_code_lines12="$(grep -v '^[[:space:]]*#' "$PLUGIN_FILE" || true)"
if grep -qE 'pr-url\.txt|gate-aggregator-result\.json' <<< "$_code_lines12"; then
    assert_fail "[#1846/SPEC-12] plugin.sh must not construct pr-url.txt or gate-aggregator-result.json paths" \
        "hardcoded input path found in non-comment code"
else
    assert_pass "[#1846/SPEC-12] plugin.sh constructs no pr-url.txt or gate-aggregator-result.json path"
fi

if grep -q 'ZBUILD_STAGE_INPUTS' "$PLUGIN_FILE"; then
    assert_pass "[#1846/SPEC-12] plugin.sh references ZBUILD_STAGE_INPUTS for input resolution"
else
    assert_fail "[#1846/SPEC-12] plugin.sh must reference ZBUILD_STAGE_INPUTS for input resolution" \
        "ZBUILD_STAGE_INPUTS not found in plugin.sh"
fi

# ---------------------------------------------------------------------------
# [#1846/SPEC-13]: all error exit paths return rc=1; no exit path returns rc=2+
# ---------------------------------------------------------------------------
_code_lines13="$(grep -v '^[[:space:]]*#' "$PLUGIN_FILE" 2>/dev/null || true)"
_high_rc="$(grep -E '\b(exit|return)[[:space:]]+[2-9]' <<< "$_code_lines13" 2>/dev/null || true)"
if [[ -z "$_high_rc" ]]; then
    assert_pass "[#1846/SPEC-13] plugin.sh has no non-comment exit/return with rc>=2"
else
    assert_fail "[#1846/SPEC-13] plugin.sh must not exit/return with rc>=2 on any code path" \
        "$_high_rc"
fi

# ---------------------------------------------------------------------------
# [#1846/SPEC-9]: manifest provides block declares result_contract: 2
# ---------------------------------------------------------------------------
_s9_provides="$(awk '/^provides:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'result_contract:.*2' <<< "$_s9_provides"; then
    assert_pass "[#1846/SPEC-9] manifest provides block carries result_contract: 2"
else
    assert_fail "[#1846/SPEC-9] manifest provides block must carry result_contract: 2" \
        "${_s9_provides:-absent}"
fi

# ---------------------------------------------------------------------------
# [#1846/SPEC-15]: manifest has no config.router block; manifest_router_knob
#                  returns empty for timeout_s and max_turns
# ---------------------------------------------------------------------------
_s15_timeout="$(manifest_router_knob "$_MANIFEST" timeout_s)"
_s15_maxturns="$(manifest_router_knob "$_MANIFEST" max_turns)"
assert_eq "[#1846/SPEC-15] manifest_router_knob timeout_s returns empty (no config.router)" \
    "" "$_s15_timeout"
assert_eq "[#1846/SPEC-15] manifest_router_knob max_turns returns empty (no config.router)" \
    "" "$_s15_maxturns"

# ---------------------------------------------------------------------------
# [#1846/SPEC-16]: manifest outputs.deploy_result retains primary: true
# ---------------------------------------------------------------------------
_s16_stanza="$(awk \
    '/id: deploy_result/{f=1} f{print} f && /^[[:space:]]*-[[:space:]]*id:/ && !/deploy_result/{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'primary: true' <<< "$_s16_stanza"; then
    assert_pass "[#1846/SPEC-16] manifest outputs deploy_result declares primary: true"
else
    assert_fail "[#1846/SPEC-16] manifest outputs deploy_result must declare primary: true" \
        "${_s16_stanza:-absent}"
fi

# ---------------------------------------------------------------------------
# [#1846/SPEC-17]: manifest provides.role = deploy_agent;
#                  provides.events = exactly the four declared events
# ---------------------------------------------------------------------------
_s17_provides="$(awk '/^provides:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'role:[[:space:]]*deploy_agent' <<< "$_s17_provides"; then
    assert_pass "[#1846/SPEC-17] manifest provides.role declares deploy_agent"
else
    assert_fail "[#1846/SPEC-17] manifest provides.role must declare deploy_agent" \
        "${_s17_provides:-absent}"
fi

_s17_events="$(awk \
    '/events:/{f=1;next} f && /^[[:space:]]*-/{print;next} f && /^[^[:space:]-]/{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
for _ev in deploy.gate.missing deploy.input.missing deploy.skipped deploy.tool.failed; do
    if grep -q "$_ev" <<< "$_s17_events"; then
        assert_pass "[#1846/SPEC-17] manifest provides.events declares $_ev"
    else
        assert_fail "[#1846/SPEC-17] manifest provides.events must declare $_ev" \
            "${_s17_events:-absent}"
    fi
done
_s17_count="$(grep -c '^[[:space:]]*-' <<< "$_s17_events" 2>/dev/null || printf '0')"
assert_eq "[#1846/SPEC-17] manifest provides.events declares exactly 4 events" "4" "$_s17_count"

# ---------------------------------------------------------------------------
# [#1846/SPEC-18]: manifest hooks block declares only run: deploy_agent_run;
#                  no cleanup: entry
# ---------------------------------------------------------------------------
_s18_hooks="$(awk '/^hooks:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'run:' <<< "$_s18_hooks"; then
    assert_pass "[#1846/SPEC-18] manifest hooks block declares run hook"
else
    assert_fail "[#1846/SPEC-18] manifest hooks block must declare run hook" "absent"
fi
if grep -q 'cleanup:' <<< "$_s18_hooks"; then
    assert_fail "[#1846/SPEC-18] manifest hooks block must not declare cleanup hook" \
        "cleanup hook found"
else
    assert_pass "[#1846/SPEC-18] manifest hooks block has no cleanup hook"
fi
_s18_hook_count="$(grep -cE '^[[:space:]]+[a-z_]+:' <<< "$_s18_hooks" 2>/dev/null || printf '0')"
assert_eq "[#1846/SPEC-18] manifest hooks block declares exactly one hook (run only)" "1" "$_s18_hook_count"

# ---------------------------------------------------------------------------
# [#1846/SPEC-22]: manifest config.valid_verdicts lists exactly:
#                  deployed, error, skipped
# ---------------------------------------------------------------------------
_s22_section="$(awk '/valid_verdicts:/{f=1;next} f && /^[[:space:]]*-/{print;next} f{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
for _vv in deployed error skipped; do
    if grep -q "$_vv" <<< "$_s22_section"; then
        assert_pass "[#1846/SPEC-22] manifest valid_verdicts contains '$_vv'"
    else
        assert_fail "[#1846/SPEC-22] manifest valid_verdicts must contain '$_vv'" \
            "${_s22_section:-absent}"
    fi
done
_s22_count="$(grep -c '^[[:space:]]*-' <<< "$_s22_section" 2>/dev/null || printf '0')"
assert_eq "[#1846/SPEC-22] manifest config.valid_verdicts declares exactly 3 verdicts" "3" "$_s22_count"

# ===========================================================================
# Runtime assertions — exercising the plugin logic
# ===========================================================================

# Set up the deploy-release mock load guard BEFORE any runtime test that
# might trigger delegation, so the real plugin.sh is never sourced.
_ZBUILD_DEPLOY_RELEASE_LOADED=1
_MOCK_DR_CALLED=0
_MOCK_DR_RC=0
# deploy_release_run mock — writes a v2 deploy-result.json into ZBUILD_ARTIFACT_DIR
deploy_release_run() {
    _MOCK_DR_CALLED=1
    local _pr_url="${ZBUILD_PR_URL:-https://github.com/test/repo/pull/42}"
    jq -n --arg pu "$_pr_url" \
        '{result_contract:2,verdict:"deployed",disposition:"complete",reason:"release created",data:{pr_url:$pu}}' \
        > "$ZBUILD_ARTIFACT_DIR/deploy-result.json"
    return "$_MOCK_DR_RC"
}

# ---------------------------------------------------------------------------
# [#1846/SPEC-2]: ZBUILD_DRY_RUN=1 writes deploy-result.json with verdict=deployed
# ---------------------------------------------------------------------------
_run2="$TEST_TEMP_DIR/run2"
_make_state "$_run2" "https://github.com/test/repo/pull/42"
ZBUILD_DRY_RUN=1 _deploy_agent_run_inner "$_MS_SF"
_dry_verdict2="$(jq -r '.verdict' "$_run2/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[#1846/SPEC-2] dry-run writes verdict=deployed" "deployed" "$_dry_verdict2"

# non-dry-run with passing gate delegates to deploy_release_run
_MOCK_DR_CALLED=0
_run2b="$TEST_TEMP_DIR/run2b"
_make_state "$_run2b" "https://github.com/test/repo/pull/42" "pass"
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_MS_SF"
assert_eq "[#1846/SPEC-2] non-dry-run with passing gate delegates to deploy_release_run" \
    "1" "$_MOCK_DR_CALLED"

# ---------------------------------------------------------------------------
# [#1846/SPEC-3]: missing pr_url input → deploy_agent_run exits non-zero + verdict=error
# ---------------------------------------------------------------------------
_run3="$TEST_TEMP_DIR/run3"
# Build an inputs index with NO pr_url entry
mkdir -p "$_run3/artifacts" "$_run3/stage-inputs"
jq -n '{"inputs":{}}' > "$_run3/stage-inputs/deploy.json"
export ZBUILD_STAGE_INPUTS="$_run3/stage-inputs/deploy.json"
export ZBUILD_ARTIFACT_DIR="$_run3/artifacts"
printf '{"issue":"%s","run_id":"%s"}\n' "$_ZB_ID" "$ZBUILD_RUN_ID" > "$_run3/state.json"

_rc3=0
_deploy_agent_run_inner "$_run3/state.json" || _rc3=$?
assert_gt "[#1846/SPEC-3] missing pr_url → rc != 0" "$_rc3" "0"
_v3="$(jq -r '.verdict' "$_run3/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[#1846/SPEC-3] missing pr_url → verdict=error in output" "error" "$_v3"

# ---------------------------------------------------------------------------
# [#1846/SPEC-4]: gate verdict=fail → deploy-result.json verdict=skipped
# ---------------------------------------------------------------------------
_run4="$TEST_TEMP_DIR/run4"
_make_state "$_run4" "https://github.com/test/repo/pull/42" "fail"
_deploy_agent_run_inner "$_MS_SF"
_v4="$(jq -r '.verdict' "$_run4/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[#1846/SPEC-4] gate verdict=fail → deploy-result verdict=skipped" "skipped" "$_v4"

# gate verdict=route_design (non-pass, non-fail) — fail-closed allowlist must also skip
_run4b="$TEST_TEMP_DIR/run4b"
_make_state "$_run4b" "https://github.com/test/repo/pull/42" "route_design"
_deploy_agent_run_inner "$_MS_SF"
_v4b="$(jq -r '.verdict' "$_run4b/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[#1846/SPEC-4] gate verdict=route_design (non-pass) → skipped (allowlist)" "skipped" "$_v4b"

# ---------------------------------------------------------------------------
# [#1846/SPEC-7]: dry-run deploy-result.json carries result_contract=2 (not schema_version=1)
# ---------------------------------------------------------------------------
_run7="$TEST_TEMP_DIR/run7"
_make_state "$_run7" "https://github.com/test/repo/pull/42"
ZBUILD_DRY_RUN=1 _deploy_agent_run_inner "$_MS_SF"
_rc7="$(jq -r '.result_contract // empty' "$_run7/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[#1846/SPEC-7] dry-run deploy-result.json carries result_contract=2" "2" "$_rc7"
_sv7="$(jq -r '.schema_version // "ABSENT"' "$_run7/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[#1846/SPEC-7] dry-run deploy-result.json must not carry schema_version key" "ABSENT" "$_sv7"

# ---------------------------------------------------------------------------
# [#1846/SPEC-8]: missing gate (non-dry-run) → fail-closed returns rc=1 (not rc=2)
# ---------------------------------------------------------------------------
_run8="$TEST_TEMP_DIR/run8"
# Provide pr_url but NO gate_aggregator_result
_make_state "$_run8" "https://github.com/test/repo/pull/42"
# Overwrite the inputs index to omit gate_aggregator_result
jq -n --arg pu "$_run8/stage-inputs/pr-url.txt" \
    '{"inputs":{"pr_url":$pu}}' > "$_run8/stage-inputs/deploy.json"
export ZBUILD_STAGE_INPUTS="$_run8/stage-inputs/deploy.json"

_rc8=0
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_run8/state.json" || _rc8=$?
assert_eq "[#1846/SPEC-8] missing gate (non-dry-run) → fail-closed rc=1 (not rc=2)" "1" "$_rc8"
_v8="$(jq -r '.verdict' "$_run8/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[#1846/SPEC-8] missing gate → verdict=error" "error" "$_v8"

# ---------------------------------------------------------------------------
# [#1846/SPEC-19]: dry-run deploy-result.json carries full v2 envelope:
#                  verdict=deployed, disposition=complete, reason present
# ---------------------------------------------------------------------------
_run19="$TEST_TEMP_DIR/run19"
_make_state "$_run19" "https://github.com/test/repo/pull/42"
ZBUILD_DRY_RUN=1 _deploy_agent_run_inner "$_MS_SF"
_s19_out="$_run19/artifacts/deploy-result.json"

assert_eq "[#1846/SPEC-19] dry-run writes result_contract=2" \
    "2" "$(jq -r '.result_contract // empty' "$_s19_out" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-19] dry-run writes verdict=deployed" \
    "deployed" "$(jq -r '.verdict // empty' "$_s19_out" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-19] dry-run writes disposition=complete" \
    "complete" "$(jq -r '.disposition // empty' "$_s19_out" 2>/dev/null || printf MISSING)"
_s19_reason="$(jq -r '.reason // ""' "$_s19_out" 2>/dev/null || true)"
if [[ -n "$_s19_reason" ]]; then
    assert_pass "[#1846/SPEC-19] dry-run writes non-empty reason"
else
    assert_fail "[#1846/SPEC-19] dry-run result must have non-empty reason" "empty or absent"
fi

# ---------------------------------------------------------------------------
# [#1846/SPEC-20]: deploy-release returns non-zero → deploy-result.json
#                  disposition=unavailable
# ---------------------------------------------------------------------------
_MOCK_DR_RC=1
_run20="$TEST_TEMP_DIR/run20"
_make_state "$_run20" "https://github.com/test/repo/pull/42" "pass"
# Override mock to return rc=1 without writing the result (plugin must write it)
deploy_release_run() {
    _MOCK_DR_CALLED=1
    return 1
}
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_MS_SF" || true
_dp20="$(jq -r '.disposition // empty' "$_run20/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[#1846/SPEC-20] deploy-release rc!=0 → disposition=unavailable" "unavailable" "$_dp20"
_v20="$(jq -r '.verdict // empty' "$_run20/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[#1846/SPEC-20] deploy-release rc!=0 → verdict=error" "error" "$_v20"
_MOCK_DR_RC=0

# Restore mock to success variant for subsequent tests
deploy_release_run() {
    _MOCK_DR_CALLED=1
    jq -n '{result_contract:2,verdict:"deployed",disposition:"complete",reason:"release created",data:{}}' \
        > "$ZBUILD_ARTIFACT_DIR/deploy-result.json"
    return 0
}

# ---------------------------------------------------------------------------
# [#1846/SPEC-21]: deploy-release plugin file absent → deploy-result.json
#                  disposition=broken
# ---------------------------------------------------------------------------
# Temporarily point _DEPLOY_ROOT at a dir with no deploy-release plugin
_saved_deploy_root="$_DEPLOY_ROOT"
_DEPLOY_ROOT="$TEST_TEMP_DIR/no-release-plugin"
mkdir -p "$TEST_TEMP_DIR/no-release-plugin"
# Unset the load guard so the plugin path check triggers
unset _ZBUILD_DEPLOY_RELEASE_LOADED 2>/dev/null || true
unset -f deploy_release_run 2>/dev/null || true

_run21="$TEST_TEMP_DIR/run21"
_make_state "$_run21" "https://github.com/test/repo/pull/42" "pass"
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_MS_SF" || true
_dp21="$(jq -r '.disposition // empty' "$_run21/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[#1846/SPEC-21] deploy-release absent → disposition=broken" "broken" "$_dp21"
_v21="$(jq -r '.verdict // empty' "$_run21/artifacts/deploy-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[#1846/SPEC-21] deploy-release absent → verdict=error" "error" "$_v21"

# Restore
_DEPLOY_ROOT="$_saved_deploy_root"
_ZBUILD_DEPLOY_RELEASE_LOADED=1
deploy_release_run() {
    _MOCK_DR_CALLED=1
    jq -n '{result_contract:2,verdict:"deployed",disposition:"complete",reason:"release created",data:{}}' \
        > "$ZBUILD_ARTIFACT_DIR/deploy-result.json"
    return 0
}

# ---------------------------------------------------------------------------
# [#1846/SPEC-10]: every terminal exit path writes v2 envelope
# ---------------------------------------------------------------------------

# Path 1 — missing pr_url (broken disposition)
_run10a="$TEST_TEMP_DIR/run10a"
mkdir -p "$_run10a/artifacts" "$_run10a/stage-inputs"
jq -n '{"inputs":{}}' > "$_run10a/stage-inputs/deploy.json"
export ZBUILD_STAGE_INPUTS="$_run10a/stage-inputs/deploy.json"
export ZBUILD_ARTIFACT_DIR="$_run10a/artifacts"
printf '{"run_id":"%s"}\n' "$ZBUILD_RUN_ID" > "$_run10a/state.json"
_deploy_agent_run_inner "$_run10a/state.json" || true
_v2_keys_ok "[#1846/SPEC-10] missing-pr_url exit path:" "$_run10a/artifacts/deploy-result.json"

# Path 2 — dry-run (complete disposition)
_run10b="$TEST_TEMP_DIR/run10b"
_make_state "$_run10b" "https://github.com/test/repo/pull/42"
ZBUILD_DRY_RUN=1 _deploy_agent_run_inner "$_MS_SF"
_v2_keys_ok "[#1846/SPEC-10] dry-run exit path:" "$_run10b/artifacts/deploy-result.json"

# Path 3 — gate verdict=fail → skipped (complete disposition)
_run10c="$TEST_TEMP_DIR/run10c"
_make_state "$_run10c" "https://github.com/test/repo/pull/42" "fail"
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_MS_SF"
_v2_keys_ok "[#1846/SPEC-10] skipped (gate-fail) exit path:" "$_run10c/artifacts/deploy-result.json"

# Path 4 — missing gate (non-dry-run) → error/broken
_run10d="$TEST_TEMP_DIR/run10d"
_make_state "$_run10d" "https://github.com/test/repo/pull/42"
jq -n --arg pu "$_run10d/stage-inputs/pr-url.txt" \
    '{"inputs":{"pr_url":$pu}}' > "$_run10d/stage-inputs/deploy.json"
export ZBUILD_STAGE_INPUTS="$_run10d/stage-inputs/deploy.json"
export ZBUILD_ARTIFACT_DIR="$_run10d/artifacts"
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_run10d/state.json" || true
_v2_keys_ok "[#1846/SPEC-10] missing-gate exit path:" "$_run10d/artifacts/deploy-result.json"

# Path 5 — deploy-release returns non-zero (unavailable disposition)
_run10e="$TEST_TEMP_DIR/run10e"
_make_state "$_run10e" "https://github.com/test/repo/pull/42" "pass"
deploy_release_run() { return 1; }
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_MS_SF" || true
_v2_keys_ok "[#1846/SPEC-10] deploy-release-failed exit path:" "$_run10e/artifacts/deploy-result.json"
deploy_release_run() {
    _MOCK_DR_CALLED=1
    jq -n '{result_contract:2,verdict:"deployed",disposition:"complete",reason:"release created",data:{}}' \
        > "$ZBUILD_ARTIFACT_DIR/deploy-result.json"
    return 0
}

# Path 6 — deploy-release plugin absent (broken disposition)
_run10f="$TEST_TEMP_DIR/run10f"
_DEPLOY_ROOT="$TEST_TEMP_DIR/no-release-plugin"
unset _ZBUILD_DEPLOY_RELEASE_LOADED 2>/dev/null || true
unset -f deploy_release_run 2>/dev/null || true
_make_state "$_run10f" "https://github.com/test/repo/pull/42" "pass"
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_MS_SF" || true
_v2_keys_ok "[#1846/SPEC-10] deploy-release-absent exit path:" "$_run10f/artifacts/deploy-result.json"
_DEPLOY_ROOT="$_saved_deploy_root"
_ZBUILD_DEPLOY_RELEASE_LOADED=1
deploy_release_run() {
    _MOCK_DR_CALLED=1
    jq -n '{result_contract:2,verdict:"deployed",disposition:"complete",reason:"release created",data:{}}' \
        > "$ZBUILD_ARTIFACT_DIR/deploy-result.json"
    return 0
}

# Path 7 — success (complete disposition)
_MOCK_DR_CALLED=0
_run10g="$TEST_TEMP_DIR/run10g"
_make_state "$_run10g" "https://github.com/test/repo/pull/42" "pass"
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_MS_SF"
_v2_keys_ok "[#1846/SPEC-10] success exit path:" "$_run10g/artifacts/deploy-result.json"

# ---------------------------------------------------------------------------
# [#1846/SPEC-13]: all error exit paths return rc=1; no exit path returns rc=2+
#                  (static check already done above; dynamic spot-checks below)
# ---------------------------------------------------------------------------

# Missing pr_url → must be rc=1
_run13a="$TEST_TEMP_DIR/run13a"
mkdir -p "$_run13a/artifacts" "$_run13a/stage-inputs"
jq -n '{"inputs":{}}' > "$_run13a/stage-inputs/deploy.json"
export ZBUILD_STAGE_INPUTS="$_run13a/stage-inputs/deploy.json"
export ZBUILD_ARTIFACT_DIR="$_run13a/artifacts"
printf '{"run_id":"%s"}\n' "$ZBUILD_RUN_ID" > "$_run13a/state.json"
_rc13a=0
_deploy_agent_run_inner "$_run13a/state.json" || _rc13a=$?
assert_eq "[#1846/SPEC-13] missing pr_url exits with rc=1 (not rc=2)" "1" "$_rc13a"

# Missing gate → must be rc=1
_run13b="$TEST_TEMP_DIR/run13b"
_make_state "$_run13b" "https://github.com/test/repo/pull/42"
jq -n --arg pu "$_run13b/stage-inputs/pr-url.txt" \
    '{"inputs":{"pr_url":$pu}}' > "$_run13b/stage-inputs/deploy.json"
export ZBUILD_STAGE_INPUTS="$_run13b/stage-inputs/deploy.json"
export ZBUILD_ARTIFACT_DIR="$_run13b/artifacts"
_rc13b=0
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_run13b/state.json" || _rc13b=$?
assert_eq "[#1846/SPEC-13] missing gate exits with rc=1 (not rc=2)" "1" "$_rc13b"

# Deploy-release rc=5 → must be clamped to rc=1
_run13c="$TEST_TEMP_DIR/run13c"
_make_state "$_run13c" "https://github.com/test/repo/pull/42" "pass"
deploy_release_run() { return 5; }
_rc13c=0
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_MS_SF" || _rc13c=$?
assert_eq "[#1846/SPEC-13] deploy-release rc=5 exits with rc=1 (clamped)" "1" "$_rc13c"
deploy_release_run() {
    _MOCK_DR_CALLED=1
    jq -n '{result_contract:2,verdict:"deployed",disposition:"complete",reason:"release created",data:{}}' \
        > "$ZBUILD_ARTIFACT_DIR/deploy-result.json"
    return 0
}

# Missing deploy-release plugin → must be rc=1
_run13d="$TEST_TEMP_DIR/run13d"
_DEPLOY_ROOT="$TEST_TEMP_DIR/no-release-plugin"
unset _ZBUILD_DEPLOY_RELEASE_LOADED 2>/dev/null || true
unset -f deploy_release_run 2>/dev/null || true
_make_state "$_run13d" "https://github.com/test/repo/pull/42" "pass"
_rc13d=0
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_MS_SF" || _rc13d=$?
assert_eq "[#1846/SPEC-13] missing deploy-release plugin exits with rc=1 (not rc=2)" "1" "$_rc13d"
_DEPLOY_ROOT="$_saved_deploy_root"
_ZBUILD_DEPLOY_RELEASE_LOADED=1
deploy_release_run() {
    _MOCK_DR_CALLED=1
    jq -n '{result_contract:2,verdict:"deployed",disposition:"complete",reason:"release created",data:{}}' \
        > "$ZBUILD_ARTIFACT_DIR/deploy-result.json"
    return 0
}

# ---------------------------------------------------------------------------
# [#1846/SPEC-14]: all three valid verdicts (deployed, error, skipped) are
#                  exercised with v2-shaped result in tests
# ---------------------------------------------------------------------------

# deployed verdict — via dry-run (already exercised above; confirm v2)
_run14a="$TEST_TEMP_DIR/run14a"
_make_state "$_run14a" "https://github.com/test/repo/pull/42"
ZBUILD_DRY_RUN=1 _deploy_agent_run_inner "$_MS_SF"
assert_eq "[#1846/SPEC-14] deployed verdict (dry-run) has result_contract=2" \
    "2" "$(jq -r '.result_contract // empty' "$_run14a/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-14] deployed verdict (dry-run) is 'deployed'" \
    "deployed" "$(jq -r '.verdict // empty' "$_run14a/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"

# error verdict — via missing pr_url
_run14b="$TEST_TEMP_DIR/run14b"
mkdir -p "$_run14b/artifacts" "$_run14b/stage-inputs"
jq -n '{"inputs":{}}' > "$_run14b/stage-inputs/deploy.json"
export ZBUILD_STAGE_INPUTS="$_run14b/stage-inputs/deploy.json"
export ZBUILD_ARTIFACT_DIR="$_run14b/artifacts"
printf '{"run_id":"%s"}\n' "$ZBUILD_RUN_ID" > "$_run14b/state.json"
_deploy_agent_run_inner "$_run14b/state.json" || true
assert_eq "[#1846/SPEC-14] error verdict (missing pr_url) has result_contract=2" \
    "2" "$(jq -r '.result_contract // empty' "$_run14b/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-14] error verdict (missing pr_url) is 'error'" \
    "error" "$(jq -r '.verdict // empty' "$_run14b/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"

# skipped verdict — via gate=fail
_run14c="$TEST_TEMP_DIR/run14c"
_make_state "$_run14c" "https://github.com/test/repo/pull/42" "fail"
ZBUILD_DRY_RUN=0 _deploy_agent_run_inner "$_MS_SF"
assert_eq "[#1846/SPEC-14] skipped verdict (gate-fail) has result_contract=2" \
    "2" "$(jq -r '.result_contract // empty' "$_run14c/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-14] skipped verdict (gate-fail) is 'skipped'" \
    "skipped" "$(jq -r '.verdict // empty' "$_run14c/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"

# ─── Cleanup ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
