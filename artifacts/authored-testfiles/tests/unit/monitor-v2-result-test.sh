#!/usr/bin/env bash
# tests/unit/monitor-v2-result-test.sh
# Contract v2 result assertions for the monitor plugin (issue #1847, Phase 0/F).
# SPEC coverage:
#   [#1847/SPEC-1]  manifest declares provides.result_contract: 2
#   [#1847/SPEC-2]  dry-run monitor-report.json carries result_contract:2, disposition:complete
#   [#1847/SPEC-3]  live pass-path monitor-report.json carries result_contract:2, disposition:complete,
#                   verdict:pass unchanged
#   [#1847/SPEC-4]  route_to_model failure path carries a disposition derived via
#                   router_reason_disposition, not a bare verdict:degraded with no disposition
#   [#1847/SPEC-5]  unparseable/schema-gate-failed reply path carries disposition:unusable
#   [#1847/SPEC-6]  SIGTERM during route_to_model writes disposition:interrupted before rc=130
#   [#1847/SPEC-7]  manifest declares config.router {timeout_s:300, max_turns:10}
#   [#1847/SPEC-8]  assembled prompt contains a TURN BUDGET block before route_to_model
#   [#1847/SPEC-9]  assembled prompt contains a WALL CLOCK BUDGET block before route_to_model
#   [#1847/SPEC-11] config.valid_verdicts remains exactly [pass, degraded]
#   [#1847/SPEC-12] inputs: declares only {deploy_result, pr_url}, both required:false, no restated source/path/type
#   [#1847/SPEC-14] ZBUILD_STAGE_INPUTS-resolved deploy_result/pr_url win over the hardcoded artifacts_dir paths
#   [#1847/SPEC-15] outputs: block still declares exactly one primary:true entry
#   [#1847/SPEC-16] provides.role: monitor unchanged
#   [#1847/SPEC-18] no hardcoded artifacts_dir deploy-result/pr-url construction; no fallback path
#   [#1847/SPEC-19] manifest declares no top-level cleanup: key; ADR-054 §7 comment present
#   [#1847/SPEC-20] reason field always present (empty string) on every complete-disposition exit path
#   [#1847/SPEC-21] monitor_stage_run never returns an rc outside {0,1}
#   [#1847/SPEC-22] template accessor still outranks monitor's own manifest config.router
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "monitor plugin: v2 result contract (issue #1847)"
setup_test_env "monitor-v2-result"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="monitor-v2-test-$$"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/monitor"
MON_MANIFEST="$PLUGIN_DIR/manifest.yaml"

# ─── SPEC-1: manifest declares provides.result_contract: 2 ──────────────────
print_test_section "[#1847/SPEC-1] manifest declares provides.result_contract: 2"

_s1_rc="$(awk '/^provides:/{f=1;next} f && /^[a-zA-Z]/{f=0} f && /result_contract:/{print $2; exit}' "$MON_MANIFEST" || echo '')"
assert_eq "[#1847/SPEC-1] manifest provides.result_contract is 2" "2" "$_s1_rc"

# ─── SPEC-7: manifest declares config.router {timeout_s:300, max_turns:10} ──
print_test_section "[#1847/SPEC-7] manifest declares config.router timeout_s:300, max_turns:10"

_s7_router_block="$(grep -A3 '^[[:space:]]*router:' "$MON_MANIFEST" 2>/dev/null || true)"
_s7_timeout="$(grep 'timeout_s:' <<< "$_s7_router_block" | awk '{print $2}' || echo '')"
_s7_maxturns="$(grep 'max_turns:' <<< "$_s7_router_block" | awk '{print $2}' || echo '')"
assert_eq "[#1847/SPEC-7] manifest config.router.timeout_s is 300" "300" "$_s7_timeout"
assert_eq "[#1847/SPEC-7] manifest config.router.max_turns is 10" "10" "$_s7_maxturns"

# ─── SPEC-11: config.valid_verdicts remains exactly [pass, degraded] ─────────
print_test_section "[#1847/SPEC-11] config.valid_verdicts remains exactly [pass, degraded]"

_s11_stanza="$(awk '
    /^[[:space:]]*valid_verdicts:/ { f=1; next }
    f && /^[[:space:]]*-[[:space:]]/ { print; next }
    f { exit }
' "$MON_MANIFEST" 2>/dev/null || true)"
_s11_count="$(grep -c '^[[:space:]]*-[[:space:]]' <<< "$_s11_stanza" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-11] valid_verdicts has exactly 2 entries" "2" "$_s11_count"
if grep -qx '[[:space:]]*- pass' <<< "$_s11_stanza"; then
    assert_pass "[#1847/SPEC-11] valid_verdicts includes pass"
else
    assert_fail "[#1847/SPEC-11] valid_verdicts includes pass" "${_s11_stanza:-absent}"
fi
if grep -qx '[[:space:]]*- degraded' <<< "$_s11_stanza"; then
    assert_pass "[#1847/SPEC-11] valid_verdicts includes degraded"
else
    assert_fail "[#1847/SPEC-11] valid_verdicts includes degraded" "${_s11_stanza:-absent}"
fi

# ─── SPEC-12: inputs: declares only {deploy_result, pr_url}, both required:false ─
print_test_section "[#1847/SPEC-12] inputs: declares only deploy_result and pr_url, both required:false, no source/path/type"

_s12_inputs="$(awk '
    /^inputs:/ { f=1; next }
    f && /^[a-zA-Z]/ { exit }
    f { print }
' "$MON_MANIFEST" 2>/dev/null || true)"
_s12_id_count="$(grep -c '^[[:space:]]*-[[:space:]]*id:' <<< "$_s12_inputs" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-12] inputs: declares exactly 2 input ids" "2" "$_s12_id_count"
if grep -q 'id:[[:space:]]*deploy_result' <<< "$_s12_inputs"; then
    assert_pass "[#1847/SPEC-12] inputs: declares deploy_result"
else
    assert_fail "[#1847/SPEC-12] inputs: declares deploy_result" "${_s12_inputs:-absent}"
fi
if grep -q 'id:[[:space:]]*pr_url' <<< "$_s12_inputs"; then
    assert_pass "[#1847/SPEC-12] inputs: declares pr_url"
else
    assert_fail "[#1847/SPEC-12] inputs: declares pr_url" "${_s12_inputs:-absent}"
fi
_s12_required_false_count="$(grep -c 'required:[[:space:]]*false' <<< "$_s12_inputs" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-12] inputs: both entries have required:false" "2" "$_s12_required_false_count"
_s12_restated="$(grep -cE '^\s*(source|path|type):' <<< "$_s12_inputs" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-12] inputs: no restated source/path/type keys" "0" "$_s12_restated"

# ─── SPEC-15: outputs: block still declares exactly one primary:true entry ───
print_test_section "[#1847/SPEC-15] outputs: block declares exactly one primary:true entry (monitor_report)"

_s15_primary_count="$(grep -c 'primary:[[:space:]]*true' "$MON_MANIFEST" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-15] manifest has exactly one primary:true output" "1" "$_s15_primary_count"

_s15_primary_stanza="$(awk '
    /^  - id: monitor_report/ { found=1 }
    found && /^  - id:/ && !/monitor_report/ { exit }
    found { print }
' "$MON_MANIFEST" 2>/dev/null || true)"
if grep -q 'primary:[[:space:]]*true' <<< "$_s15_primary_stanza"; then
    assert_pass "[#1847/SPEC-15] the primary:true output is monitor_report"
else
    assert_fail "[#1847/SPEC-15] the primary:true output is monitor_report" "${_s15_primary_stanza:-absent}"
fi

# ─── SPEC-16: provides.role: monitor unchanged ───────────────────────────────
print_test_section "[#1847/SPEC-16] manifest still declares provides.role: monitor"

_s16_role="$(awk '/^provides:/{f=1;next} f && /^[a-zA-Z]/{f=0} f && /^[[:space:]]*role:/{print $2; exit}' "$MON_MANIFEST" || echo '')"
assert_eq "[#1847/SPEC-16] provides.role is monitor" "monitor" "$_s16_role"

# ─── Plugin behavior setup ────────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/monitor/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$ARTIFACTS_DIR"
printf '{"schema_version":1,"run_id":"test","issue":"1847","stage_statuses":{}}\n' > "$STATE_FILE"

_CAPTURED_PROMPT_FILE="$TEST_TEMP_DIR/captured-prompt.txt"
: > "$_CAPTURED_PROMPT_FILE"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"deployment healthy","checks":[]}'
# shellcheck disable=SC2329  # invoked indirectly by the sourced plugin
route_to_model() {
    printf '%s' "${2:-}" > "$_CAPTURED_PROMPT_FILE"
    if [[ "$MOCK_ROUTE_RC" -eq 0 ]]; then
        printf '%s' "$MOCK_ROUTE_RESPONSE"
    fi
    return "$MOCK_ROUTE_RC"
}

# ─── SPEC-2: dry-run path — result_contract:2, disposition:complete ─────────
print_test_section "[#1847/SPEC-2] dry-run monitor-report.json carries result_contract:2, disposition:complete"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
export ZBUILD_DRY_RUN=1
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
_s2_rc=$?
set -e
unset ZBUILD_DRY_RUN

assert_eq "[#1847/SPEC-2] dry-run returns rc=0" "0" "$_s2_rc"
assert_file_exists "[#1847/SPEC-2] dry-run writes monitor-report.json" "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "[#1847/SPEC-2] dry-run: result_contract is 2" "2" \
    "$(jq -r '.result_contract // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-2] dry-run: disposition is complete" "complete" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-20] dry-run: reason key is present and empty" "" \
    "$(jq -r 'if has("reason") then .reason else "MISSING_KEY" end' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || echo 'MISSING_KEY')"

# ─── SPEC-3: live pass path — result_contract:2, disposition:complete, verdict:pass ─
print_test_section "[#1847/SPEC-3] live pass-path monitor-report.json carries result_contract:2, disposition:complete, verdict:pass"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"deployment healthy","checks":[]}'
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
_s3_rc=$?
set -e

assert_eq "[#1847/SPEC-3] live pass path returns rc=0" "0" "$_s3_rc"
assert_file_exists "[#1847/SPEC-3] live pass path writes monitor-report.json" "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "[#1847/SPEC-3] live pass path: result_contract is 2" "2" \
    "$(jq -r '.result_contract // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-3] live pass path: disposition is complete" "complete" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-3] live pass path: verdict is still pass (unchanged)" "pass" \
    "$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-20] live pass path: reason key is present and empty" "" \
    "$(jq -r 'if has("reason") then .reason else "MISSING_KEY" end' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || echo 'MISSING_KEY')"

# ─── SPEC-20: live degraded-verdict path (valid envelope, verdict:degraded) — ─
# disposition is still complete and reason is still "" — the health verdict
# itself (data.summary/data.checks), not disposition/reason, communicates the
# degradation (a separate axis, per ADR-054 §6).
print_test_section "[#1847/SPEC-20] live degraded-verdict path: disposition:complete, reason:\"\" (verdict itself carries the degradation)"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"degraded","summary":"probe failed","checks":[]}'
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
set -e

assert_file_exists "[#1847/SPEC-20] live degraded-verdict path writes monitor-report.json" \
    "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "[#1847/SPEC-20] live degraded-verdict path: verdict is degraded" "degraded" \
    "$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-20] live degraded-verdict path: disposition is still complete" "complete" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-20] live degraded-verdict path: reason key is present and empty" "" \
    "$(jq -r 'if has("reason") then .reason else "MISSING_KEY" end' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || echo 'MISSING_KEY')"

# ─── SPEC-4: route_to_model failure path — disposition via router_reason_disposition ─
print_test_section "[#1847/SPEC-4] route_to_model failure path carries a disposition derived via router_reason_disposition"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
MOCK_ROUTE_RC=1
MOCK_ROUTE_RESPONSE=""
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
_s4_rc=$?
set -e

assert_file_exists "[#1847/SPEC-4] router-failure path writes monitor-report.json" "$ARTIFACTS_DIR/monitor-report.json"
_s4_disp="$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
# rc=1 with no rate-limit/timeout signal classifies via _router_rc_classify as
# router_rc_nonzero, which router_reason_disposition maps to "unavailable" — the
# generic non-empty disposition case (not a bare verdict:degraded with no field).
assert_eq "[#1847/SPEC-4] router-failure path: disposition is unavailable (router_reason_disposition mapping)" \
    "unavailable" "$_s4_disp"
# rc=1 with no rate-limit/budget-exhaustion/timeout signal classifies via
# _router_rc_classify as reason="router_rc_nonzero" — the classified router
# reason that fed the router_reason_disposition mapping above.
assert_eq "[#1847/SPEC-4] router-failure path: reason names the classified router reason" \
    "router_rc_nonzero" "$(jq -r '.reason // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
if [[ "$_s4_rc" -ne 0 ]]; then
    assert_pass "[#1847/SPEC-4] router-failure path returns non-zero rc"
else
    assert_fail "[#1847/SPEC-4] router-failure path returns non-zero rc" "rc was 0"
fi

# ─── SPEC-5: unparseable/schema-gate-failed reply path — disposition:unusable ─
print_test_section "[#1847/SPEC-5] unparseable/schema-gate-failed reply path carries disposition:unusable"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='this is not JSON at all, just prose the model produced'
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
set -e

assert_file_exists "[#1847/SPEC-5] unparseable-reply path writes monitor-report.json" "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "[#1847/SPEC-5] unparseable-reply path: disposition is unusable" "unusable" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"

# ─── SPEC-6/SPEC-21: SIGTERM/SIGINT during route_to_model writes disposition:interrupted, ─
# reason:signal_interrupt, and monitor_stage_run returns rc=1 (NOT the raw signal rc=130) ─
print_test_section "[#1847/SPEC-6] SIGTERM during route_to_model writes disposition:interrupted, reason:signal_interrupt, and monitor_stage_run returns rc=1 (not raw signal rc)"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
_s6_orig_route="$(declare -f route_to_model)"
# shellcheck disable=SC2329
route_to_model() { kill -TERM "$$"; return 130; }
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
_s6_rc=$?
set -e
eval "$_s6_orig_route"

assert_eq "[#1847/SPEC-6] SIGTERM during route_to_model: monitor_stage_run returns rc=1 (not the raw signal rc=130)" \
    "1" "$_s6_rc"
assert_file_exists "[#1847/SPEC-6] monitor-report.json written on interrupt" \
    "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "[#1847/SPEC-6] disposition is interrupted" "interrupted" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-6] reason is signal_interrupt" "signal_interrupt" \
    "$(jq -r '.reason // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"

# ─── SPEC-8/SPEC-9: TURN BUDGET / WALL CLOCK BUDGET blocks in the assembled prompt ─
print_test_section "[#1847/SPEC-8/SPEC-9] assembled prompt contains TURN BUDGET and WALL CLOCK BUDGET blocks reflecting the manifest's router budget"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
: > "$_CAPTURED_PROMPT_FILE"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"deployment healthy","checks":[]}'
export ZBUILD_PLUGIN_DIR="$PLUGIN_DIR"
unset ZBUILD_ROUTER_TIMEOUT ZBUILD_ROUTER_MAX_TURNS ZBUILD_ROUTER_MAX_TURNS_OVERRIDE ZBUILD_CURRENT_STAGE 2>/dev/null || true
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
set -e
unset ZBUILD_PLUGIN_DIR

_s89_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
_s89_turn_block="$(grep -i -A6 "TURN BUDGET" <<< "$_s89_prompt" 2>/dev/null || true)"
if [[ -n "$_s89_turn_block" ]] && grep -q '10' <<< "$_s89_turn_block"; then
    assert_pass "[#1847/SPEC-8] prompt contains a TURN BUDGET block reflecting the manifest's max_turns:10"
else
    assert_fail "[#1847/SPEC-8] prompt must contain a TURN BUDGET block reflecting max_turns:10" \
        "${_s89_turn_block:-absent}"
fi
_s89_wc_block="$(grep -i -A6 "WALL CLOCK BUDGET" <<< "$_s89_prompt" 2>/dev/null || true)"
if [[ -n "$_s89_wc_block" ]] && grep -q '300' <<< "$_s89_wc_block"; then
    assert_pass "[#1847/SPEC-9] prompt contains a WALL CLOCK BUDGET block reflecting the manifest's timeout_s:300"
else
    assert_fail "[#1847/SPEC-9] prompt must contain a WALL CLOCK BUDGET block reflecting timeout_s:300" \
        "${_s89_wc_block:-absent}"
fi

# ─── SPEC-14: ZBUILD_STAGE_INPUTS-resolved deploy_result/pr_url win over hardcoded paths ─
print_test_section "[#1847/SPEC-14] ZBUILD_STAGE_INPUTS-resolved deploy_result/pr_url content reaches the prompt instead of the artifacts_dir copies"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
_s14_custom_dir="$TEST_TEMP_DIR/spec14-custom"
mkdir -p "$_s14_custom_dir"
printf '{"decoy":false,"marker":"SPEC14_DEPLOY_MARKER"}\n' > "$_s14_custom_dir/deploy-result.json"
printf 'https://example.com/SPEC14_PR_MARKER\n' > "$_s14_custom_dir/pr-url.txt"

# Decoy content at the hardcoded artifacts_dir path: if the plugin ignores the
# index and falls back to the hardcoded path, the prompt shows THIS instead —
# so the assertion below correctly fails when ZBUILD_STAGE_INPUTS is not honored.
printf '{"decoy":true,"marker":"ARTIFACTS_DIR_DECOY"}\n' > "$ARTIFACTS_DIR/deploy-result.json"
printf 'https://example.com/ARTIFACTS_DIR_DECOY\n' > "$ARTIFACTS_DIR/pr-url.txt"

_s14_si="$TEST_TEMP_DIR/spec14-stage-inputs.json"
printf '{"inputs":{"deploy_result":"%s","pr_url":"%s"}}\n' \
    "$_s14_custom_dir/deploy-result.json" "$_s14_custom_dir/pr-url.txt" > "$_s14_si"

: > "$_CAPTURED_PROMPT_FILE"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"deployment healthy","checks":[]}'
set +e
( export ZBUILD_STAGE_INPUTS="$_s14_si"; monitor_stage_run "monitor" "$STATE_FILE" ) >/dev/null 2>&1
set -e

_s14_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -q "SPEC14_DEPLOY_MARKER" <<< "$_s14_prompt" && grep -q "SPEC14_PR_MARKER" <<< "$_s14_prompt"; then
    assert_pass "[#1847/SPEC-14] prompt reflects the ZBUILD_STAGE_INPUTS-resolved deploy_result/pr_url content"
else
    assert_fail "[#1847/SPEC-14] prompt must reflect the ZBUILD_STAGE_INPUTS-resolved deploy_result/pr_url content" \
        "${_s14_prompt:-empty}"
fi
if grep -q "ARTIFACTS_DIR_DECOY" <<< "$_s14_prompt"; then
    assert_fail "[#1847/SPEC-14] prompt must NOT reflect the artifacts_dir decoy when ZBUILD_STAGE_INPUTS is present" \
        "decoy leaked into prompt"
else
    assert_pass "[#1847/SPEC-14] prompt does not reflect the artifacts_dir decoy when ZBUILD_STAGE_INPUTS is present"
fi

# Restore clean artifacts_dir copies (undo the decoy) so later runs in this file
# don't leak stage state.
rm -f "$ARTIFACTS_DIR/deploy-result.json" "$ARTIFACTS_DIR/pr-url.txt"

# ─── SPEC-18: no hardcoded artifacts_dir deploy-result/pr-url construction ───
print_test_section "[#1847/SPEC-18] plugin.sh has no hardcoded artifacts_dir/deploy-result.json or artifacts_dir/pr-url.txt construction"

_s18_grep="$(grep -n 'artifacts_dir.*deploy-result\|artifacts_dir.*pr-url' "$PLUGIN_DIR/plugin.sh" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-18] plugin.sh contains no hardcoded artifacts_dir deploy-result/pr-url construction" \
    "" "$_s18_grep"

print_test_section "[#1847/SPEC-18] ZBUILD_STAGE_INPUTS unset with no entry: treated as not provided, no fallback path is constructed"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
unset ZBUILD_STAGE_INPUTS 2>/dev/null || true
# Decoy content at the now-removed hardcoded fallback path: if the plugin still
# constructed $artifacts_dir/deploy-result.json / pr-url.txt as a fallback, the
# prompt would show this content instead — so this assertion correctly fails
# were a fallback path still being built.
printf '{"decoy":true,"marker":"SPEC18_NO_FALLBACK_MARKER"}\n' > "$ARTIFACTS_DIR/deploy-result.json"
printf 'https://example.com/SPEC18_NO_FALLBACK_MARKER\n' > "$ARTIFACTS_DIR/pr-url.txt"
: > "$_CAPTURED_PROMPT_FILE"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"deployment healthy","checks":[]}'
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
set -e
_s18_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -q "SPEC18_NO_FALLBACK_MARKER" <<< "$_s18_prompt"; then
    assert_fail "[#1847/SPEC-18] prompt must NOT reflect artifacts_dir/deploy-result.json or pr-url.txt content when ZBUILD_STAGE_INPUTS has no entry (no fallback path construction)" \
        "marker leaked into prompt"
else
    assert_pass "[#1847/SPEC-18] with no ZBUILD_STAGE_INPUTS entry, artifacts_dir/deploy-result.json and pr-url.txt content does not reach the prompt"
fi
rm -f "$ARTIFACTS_DIR/deploy-result.json" "$ARTIFACTS_DIR/pr-url.txt"

# ─── SPEC-19: manifest declares no top-level cleanup: key; ADR-054 §7 comment present ─
print_test_section "[#1847/SPEC-19] manifest declares no top-level cleanup: key and carries a comment citing ADR-054 §7"

if grep -qE '^\s*cleanup\s*:' "$MON_MANIFEST" 2>/dev/null; then
    assert_fail "[#1847/SPEC-19] manifest.yaml must not declare a top-level cleanup: key" "found cleanup key"
else
    assert_pass "[#1847/SPEC-19] manifest.yaml declares no top-level cleanup: key"
fi
if grep -q 'ADR-054.*§7\|ADR-054.*§ *7' "$MON_MANIFEST" 2>/dev/null; then
    assert_pass "[#1847/SPEC-19] manifest.yaml carries a comment citing ADR-054 §7"
else
    assert_fail "[#1847/SPEC-19] manifest.yaml must carry a comment citing ADR-054 §7 explaining hooks.cleanup's intentional absence" \
        "comment absent"
fi

# ─── SPEC-21: router rc=10 (turn-budget exhaustion) also collapses to rc=1 ────
print_test_section "[#1847/SPEC-21] router rc=10 (turn-budget exhaustion) causes monitor_stage_run to return rc=1, never the raw rc=10"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
MOCK_ROUTE_RC=10
MOCK_ROUTE_RESPONSE=""
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
_s21_rc=$?
set -e

assert_eq "[#1847/SPEC-21] rc=10 (turn-budget) path: monitor_stage_run returns rc=1 (not the raw router rc=10)" \
    "1" "$_s21_rc"
assert_file_exists "[#1847/SPEC-21] monitor-report.json written on rc=10 path" "$ARTIFACTS_DIR/monitor-report.json"

# ─── SPEC-22: template accessor still outranks monitor's own manifest config.router ─
print_test_section "[#1847/SPEC-22] template_stage_router_timeout/max_turns still outrank monitor's manifest config.router (SPEC-7)"

_s22_manifest_timeout="$(awk '/^[[:space:]]*router:/{f=1;next} f&&/timeout_s:/{print $2;exit}' "$MON_MANIFEST" 2>/dev/null || true)"
_s22_manifest_maxturns="$(awk '/^[[:space:]]*router:/{f=1;next} f&&/max_turns:/{print $2;exit}' "$MON_MANIFEST" 2>/dev/null || true)"
# The stub values must diverge from whatever the manifest declares (SPEC-7 adds
# timeout_s:300/max_turns:10) — otherwise a passing assertion could not tell
# "the stub applied" apart from "the manifest applied and happened to match".
if [[ "$_s22_manifest_timeout" == "111" || "$_s22_manifest_maxturns" == "12" ]]; then
    assert_fail "[#1847/SPEC-22] stub values must diverge from the manifest's own config.router" \
        "manifest already declares 111/12"
fi

# shellcheck disable=SC2329
template_stage_router_timeout()   { printf '111'; }
# shellcheck disable=SC2329
template_stage_router_max_turns() { printf '12'; }

_s22_prev_plugin_dir="${ZBUILD_PLUGIN_DIR:-__UNSET__}"
_s22_prev_stage="${ZBUILD_CURRENT_STAGE:-__UNSET__}"
export ZBUILD_PLUGIN_DIR="$PLUGIN_DIR"
export ZBUILD_CURRENT_STAGE="monitor"
unset ZBUILD_ROUTER_TIMEOUT ZBUILD_ROUTER_MAX_TURNS ZBUILD_ROUTER_MAX_TURNS_OVERRIDE 2>/dev/null || true

assert_eq "[#1847/SPEC-22] _route_resolve_timeout returns the STUBBED template value, not the manifest's" \
    "111" "$(_route_resolve_timeout)"
assert_eq "[#1847/SPEC-22] _route_resolve_max_turns returns the STUBBED template value, not the manifest's" \
    "12" "$(_route_resolve_max_turns)"

unset -f template_stage_router_timeout template_stage_router_max_turns 2>/dev/null || true
if [[ "$_s22_prev_plugin_dir" == "__UNSET__" ]]; then unset ZBUILD_PLUGIN_DIR; else export ZBUILD_PLUGIN_DIR="$_s22_prev_plugin_dir"; fi
if [[ "$_s22_prev_stage" == "__UNSET__" ]]; then unset ZBUILD_CURRENT_STAGE; else export ZBUILD_CURRENT_STAGE="$_s22_prev_stage"; fi

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
