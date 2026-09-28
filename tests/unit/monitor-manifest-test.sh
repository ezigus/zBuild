#!/usr/bin/env bash
# tests/unit/monitor-manifest-test.sh
# Contract v2 MANIFEST assertions for the monitor plugin (issue #1847, Phase 0/F).
# Split from monitor-v2-result-test.sh (500-line rule, review #2221); the run
# paths stay there.
# SPEC coverage:
#    manifest declares provides.result_contract: 2
#    dry-run monitor-report.json carries result_contract:2, disposition:complete
#    live pass-path monitor-report.json carries result_contract:2, disposition:complete,
#                   verdict:pass unchanged
#    route_to_model failure path carries a disposition derived via
#                   router_reason_disposition, not a bare verdict:degraded with no disposition
#    unparseable/schema-gate-failed reply path carries disposition:unusable
#    SIGTERM during route_to_model writes disposition:interrupted before rc=130
#    manifest declares config.router {timeout_s:300, max_turns:10}
#   [#1847/SPEC-8]  assembled prompt contains a TURN BUDGET block before route_to_model
#   [#1847/SPEC-9]  assembled prompt contains a WALL CLOCK BUDGET block before route_to_model
#   config.valid_verdicts remains exactly [pass, degraded]
#   inputs: declares only {deploy_result, pr_url}, both required:false, no restated source/path/type
#   ZBUILD_STAGE_INPUTS-resolved deploy_result/pr_url win over the hardcoded artifacts_dir paths
#   [#1847/SPEC-15] outputs: block still declares exactly one primary:true entry
#   provides.role: monitor unchanged
#   no hardcoded artifacts_dir deploy-result/pr-url construction; no fallback path
#   manifest declares no top-level cleanup: key; ADR-054 §7 comment present
#   reason field always present (empty string) on every complete-disposition exit path
#   monitor_stage_run never returns an rc outside {0,1}
#   [#1847/SPEC-22] template accessor still outranks monitor's own manifest config.router
#   [#1847/SPEC-23] router rc=124 (wall-clock timeout) is classified through the shared
#                   _router_rc_classify -> router_reason_disposition chokepoint (sentinel-stub
#                   proof), distinct from the rc=10 out_of_turns case
#   [#1847/SPEC-24] rc=10 (turn-budget) path carries the literal disposition:out_of_turns,
#                   reason:budget_exhausted via its own branch — proven NOT routed through
#                   router_reason_disposition by stubbing it to a sentinel for any argument
#   [#1847/SPEC-25] live pass-path verdict/data.summary/data.checks are byte-identical to a
#                   pre-migration v1-shaped fixture, contract-v2-only fields excluded
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "monitor plugin: v2 manifest (issue #1847)"
setup_test_env "monitor-manifest"

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
print_test_section "manifest declares provides.result_contract: 2"

_s1_rc="$(awk '/^provides:/{f=1;next} f && /^[a-zA-Z]/{f=0} f && /result_contract:/{print $2; exit}' "$MON_MANIFEST" || echo '')"
assert_eq "manifest provides.result_contract is 2" "2" "$_s1_rc"

# ─── SPEC-7: manifest declares config.router {timeout_s:300, max_turns:10} ──
print_test_section "manifest declares config.router timeout_s:300, max_turns:10"

_s7_router_block="$(grep -A3 '^[[:space:]]*router:' "$MON_MANIFEST" 2>/dev/null || true)"
_s7_timeout="$(grep 'timeout_s:' <<< "$_s7_router_block" | awk '{print $2}' || echo '')"
_s7_maxturns="$(grep 'max_turns:' <<< "$_s7_router_block" | awk '{print $2}' || echo '')"
assert_eq "manifest config.router.timeout_s is 300" "300" "$_s7_timeout"
assert_eq "manifest config.router.max_turns is 10" "10" "$_s7_maxturns"

# ─── SPEC-11: config.valid_verdicts remains exactly [pass, degraded] ─────────
print_test_section "config.valid_verdicts remains exactly [pass, degraded]"

_s11_stanza="$(awk '
    /^[[:space:]]*valid_verdicts:/ { f=1; next }
    f && /^[[:space:]]*-[[:space:]]/ { print; next }
    f { exit }
' "$MON_MANIFEST" 2>/dev/null || true)"
_s11_count="$(grep -c '^[[:space:]]*-[[:space:]]' <<< "$_s11_stanza" 2>/dev/null || true)"
assert_eq "valid_verdicts has exactly 2 entries" "2" "$_s11_count"
if grep -qx '[[:space:]]*- pass' <<< "$_s11_stanza"; then
    assert_pass "valid_verdicts includes pass"
else
    assert_fail "valid_verdicts includes pass" "${_s11_stanza:-absent}"
fi
if grep -qx '[[:space:]]*- degraded' <<< "$_s11_stanza"; then
    assert_pass "valid_verdicts includes degraded"
else
    assert_fail "valid_verdicts includes degraded" "${_s11_stanza:-absent}"
fi

# ─── SPEC-12: inputs: declares only {deploy_result, pr_url}, both required:false ─
print_test_section "inputs: declares only deploy_result and pr_url, both required:false, no source/path/type"

_s12_inputs="$(awk '
    /^inputs:/ { f=1; next }
    f && /^[a-zA-Z]/ { exit }
    f { print }
' "$MON_MANIFEST" 2>/dev/null || true)"
_s12_id_count="$(grep -c '^[[:space:]]*-[[:space:]]*id:' <<< "$_s12_inputs" 2>/dev/null || true)"
assert_eq "inputs: declares exactly 2 input ids" "2" "$_s12_id_count"
if grep -q 'id:[[:space:]]*deploy_result' <<< "$_s12_inputs"; then
    assert_pass "inputs: declares deploy_result"
else
    assert_fail "inputs: declares deploy_result" "${_s12_inputs:-absent}"
fi
if grep -q 'id:[[:space:]]*pr_url' <<< "$_s12_inputs"; then
    assert_pass "inputs: declares pr_url"
else
    assert_fail "inputs: declares pr_url" "${_s12_inputs:-absent}"
fi
_s12_required_false_count="$(grep -c 'required:[[:space:]]*false' <<< "$_s12_inputs" 2>/dev/null || true)"
assert_eq "inputs: both entries have required:false" "2" "$_s12_required_false_count"
_s12_restated="$(grep -cE '^\s*(source|path|type):' <<< "$_s12_inputs" 2>/dev/null || true)"
assert_eq "inputs: no restated source/path/type keys" "0" "$_s12_restated"

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
print_test_section "manifest still declares provides.role: monitor"

_s16_role="$(awk '/^provides:/{f=1;next} f && /^[a-zA-Z]/{f=0} f && /^[[:space:]]*role:/{print $2; exit}' "$MON_MANIFEST" || echo '')"
assert_eq "provides.role is monitor" "monitor" "$_s16_role"

# ─── SPEC-19: manifest declares no top-level cleanup: key; ADR-054 §7 comment present ─
print_test_section "manifest declares no top-level cleanup: key and carries a comment citing ADR-054 §7"

if grep -qE '^\s*cleanup\s*:' "$MON_MANIFEST" 2>/dev/null; then
    assert_fail "manifest.yaml must not declare a top-level cleanup: key" "found cleanup key"
else
    assert_pass "manifest.yaml declares no top-level cleanup: key"
fi
if grep -q 'ADR-054.*§7\|ADR-054.*§ *7' "$MON_MANIFEST" 2>/dev/null; then
    assert_pass "manifest.yaml carries a comment citing ADR-054 §7"
else
    assert_fail "manifest.yaml must carry a comment citing ADR-054 §7 explaining hooks.cleanup's intentional absence" \
        "comment absent"
fi

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
