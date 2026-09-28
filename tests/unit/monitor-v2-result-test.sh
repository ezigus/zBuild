#!/usr/bin/env bash
# tests/unit/monitor-v2-result-test.sh
# Contract v2 result assertions for the monitor plugin (issue #1847, Phase 0/F).
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
#                   proof), distinct from the turn-budget (out_of_turns) case
#   [#1847/SPEC-24] a turn-budget hit (rc=1 + the router's budget marker — the router
#                   never returns 10) is classified through router_reason_disposition
#                   (sentinel-stub proof); corrected after review #2221
#   [#1847/SPEC-25] live pass-path verdict/data.summary/data.checks are byte-identical to a
#                   pre-migration v1-shaped fixture, contract-v2-only fields excluded
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

# ─── Plugin behavior setup ────────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/monitor/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
STATE_FILE="$STATE_DIR/pipeline-state.json"
export ZBUILD_ARTIFACT_DIR="$STATE_DIR/artifacts"   # the engine names the output dir (review #2221)
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
print_test_section "dry-run monitor-report.json carries result_contract:2, disposition:complete"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
export ZBUILD_DRY_RUN=1
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
_s2_rc=$?
set -e
unset ZBUILD_DRY_RUN

assert_eq "dry-run returns rc=0" "0" "$_s2_rc"
assert_file_exists "dry-run writes monitor-report.json" "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "dry-run: result_contract is 2" "2" \
    "$(jq -r '.result_contract // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "dry-run: disposition is complete" "complete" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "dry-run: reason key is present and empty" "" \
    "$(jq -r 'if has("reason") then .reason else "MISSING_KEY" end' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || echo 'MISSING_KEY')"

# ─── SPEC-3: live pass path — result_contract:2, disposition:complete, verdict:pass ─
print_test_section "live pass-path monitor-report.json carries result_contract:2, disposition:complete, verdict:pass"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"deployment healthy","checks":[]}'
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
_s3_rc=$?
set -e

assert_eq "live pass path returns rc=0" "0" "$_s3_rc"
assert_file_exists "live pass path writes monitor-report.json" "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "live pass path: result_contract is 2" "2" \
    "$(jq -r '.result_contract // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "live pass path: disposition is complete" "complete" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "live pass path: verdict is still pass (unchanged)" "pass" \
    "$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "live pass path: reason key is present and empty" "" \
    "$(jq -r 'if has("reason") then .reason else "MISSING_KEY" end' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || echo 'MISSING_KEY')"

# ─── SPEC-25: carried-over health-assessment fields are byte-identical to the ─
# pre-migration v1-shaped baseline, contract-v2-only fields excluded ──────────
print_test_section "[#1847/SPEC-25] live pass-path verdict/data.summary/data.checks are byte-identical to the pre-migration v1-shaped fixture"

_s25_baseline="$PLUGIN_DIR/tests/fixtures/monitor-report-v1-baseline.json"
# The mock response mirrors the baseline fixture's flat v1 shape exactly
# (schema_version/verdict/summary/checks, no result_contract/disposition/reason,
# no data wrapper) so the comparison below is a real value diff, not a
# coincidental match.
_s25_live="$(jq -c '{schema_version, verdict, summary: .data.summary, checks: .data.checks}' \
    "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
_s25_expected="$(jq -c '{schema_version, verdict, summary, checks}' "$_s25_baseline" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-25] live pass-path health-assessment fields match the v1-shaped baseline byte-for-byte" \
    "$_s25_expected" "$_s25_live"

# ─── SPEC-20: live degraded-verdict path (valid envelope, verdict:degraded) — ─
# disposition is still complete and reason is still "" — the health verdict
# itself (data.summary/data.checks), not disposition/reason, communicates the
# degradation (a separate axis, per ADR-054 §6).
print_test_section "live degraded-verdict path: disposition:complete, reason:\"\" (verdict itself carries the degradation)"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"degraded","summary":"probe failed","checks":[]}'
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
set -e

assert_file_exists "live degraded-verdict path writes monitor-report.json" \
    "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "live degraded-verdict path: verdict is degraded" "degraded" \
    "$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "live degraded-verdict path: disposition is still complete" "complete" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "live degraded-verdict path: reason key is present and empty" "" \
    "$(jq -r 'if has("reason") then .reason else "MISSING_KEY" end' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || echo 'MISSING_KEY')"

# ─── SPEC-4: route_to_model failure path — disposition via router_reason_disposition ─
print_test_section "route_to_model failure path carries a disposition derived via router_reason_disposition"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
MOCK_ROUTE_RC=1
MOCK_ROUTE_RESPONSE=""
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
_s4_rc=$?
set -e

assert_file_exists "router-failure path writes monitor-report.json" "$ARTIFACTS_DIR/monitor-report.json"
_s4_disp="$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
# rc=1 with no rate-limit/timeout signal classifies via _router_rc_classify as
# router_rc_nonzero, which router_reason_disposition maps to "unavailable" — the
# generic non-empty disposition case (not a bare verdict:degraded with no field).
assert_eq "router-failure path: disposition is unavailable (router_reason_disposition mapping)" \
    "unavailable" "$_s4_disp"
# rc=1 with no rate-limit/budget-exhaustion/timeout signal classifies via
# _router_rc_classify as reason="router_rc_nonzero" — the classified router
# reason that fed the router_reason_disposition mapping above.
assert_eq "router-failure path: reason names the classified router reason" \
    "router_rc_nonzero" "$(jq -r '.reason // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
if [[ "$_s4_rc" -ne 0 ]]; then
    assert_pass "router-failure path returns non-zero rc"
else
    assert_fail "router-failure path returns non-zero rc" "rc was 0"
fi

# ─── SPEC-5: unparseable/schema-gate-failed reply path — disposition:unusable ─
print_test_section "unparseable/schema-gate-failed reply path carries disposition:unusable"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='this is not JSON at all, just prose the model produced'
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
set -e

assert_file_exists "unparseable-reply path writes monitor-report.json" "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "unparseable-reply path: disposition is unusable" "unusable" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"

# ─── SPEC-6/SPEC-21: SIGTERM/SIGINT during route_to_model writes disposition:interrupted, ─
# reason:signal_interrupt, and monitor_stage_run returns rc=1 (NOT the raw signal rc=130) ─
#
# The signal must land on the real process executing monitor_stage_run — no mock
# can fake a trap firing — so this forks a genuine child (bash "$_s6_child_script")
# instead of sending kill -TERM "$$" from inside this script's own process. A
# reverted implementation with no TERM trap takes the default disposition and
# dies immediately; if that kill target were this script's own PID, it would
# take down this whole file (and every assertion after it, including the
# SPEC-8/9/15/22/23/24/25 sections below) before print_test_results ever ran —
# the same #1611/#1660 self-signal hang class documented in
# harness-term-trap-test.sh and _acceptance_timeout_prefix (acceptance-block.sh).
# The gtimeout -k wrapper mirrors that same helper's fallback probing so a
# genuinely stuck child is still bounded.
print_test_section "SIGTERM during route_to_model writes disposition:interrupted, reason:signal_interrupt, and monitor_stage_run returns rc=1 (not raw signal rc)"

rm -f "$ARTIFACTS_DIR/monitor-report.json"

_s6_timeout_bin=""
if   command -v gtimeout >/dev/null 2>&1; then _s6_timeout_bin="gtimeout"
elif command -v timeout  >/dev/null 2>&1; then _s6_timeout_bin="timeout"
fi
_s6_timeout_cmd=()
if [[ -n "$_s6_timeout_bin" ]]; then
    if "$_s6_timeout_bin" -k 1 1 true >/dev/null 2>&1; then
        _s6_timeout_cmd=("$_s6_timeout_bin" -k 5 20)
    else
        _s6_timeout_cmd=("$_s6_timeout_bin" 20)
    fi
fi

_s6_child_script="$TEST_TEMP_DIR/s6-sigterm-child.sh"
cat > "$_s6_child_script" <<CHILD_EOF
#!/usr/bin/env bash
set -uo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$PLUGIN_DIR/plugin.sh"
route_to_model() { kill -TERM "\$\$"; return 130; }
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
exit "\$?"
CHILD_EOF
chmod +x "$_s6_child_script"

set +e
"${_s6_timeout_cmd[@]}" bash "$_s6_child_script" >/dev/null 2>&1
_s6_rc=$?
set -e

assert_eq "SIGTERM during route_to_model: monitor_stage_run returns rc=1 (not the raw signal rc=130)" \
    "1" "$_s6_rc"
assert_file_exists "monitor-report.json written on interrupt" \
    "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "disposition is interrupted" "interrupted" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "reason is signal_interrupt" "signal_interrupt" \
    "$(jq -r '.reason // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"

# ─── SPEC-8/SPEC-9: TURN BUDGET / WALL CLOCK BUDGET blocks reflect the value ──
# _route_resolve_max_turns / _route_resolve_timeout return AT CALL TIME — proven
# by stubbing each to a sentinel that diverges from the manifest's own
# max_turns:10 / timeout_s:300 (SPEC-7), so a prompt that merely re-read the
# manifest a second way could not pass.
print_test_section "[#1847/SPEC-8/SPEC-9] assembled prompt echoes the _route_resolve_* sentinel, not the manifest value read a second way"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
: > "$_CAPTURED_PROMPT_FILE"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"deployment healthy","checks":[]}'

_S89_TURNS_SENTINEL=77
_S89_TIMEOUT_SENTINEL=321
_s89_orig_max_turns="$(declare -f _route_resolve_max_turns)"
_s89_orig_timeout="$(declare -f _route_resolve_timeout)"
# shellcheck disable=SC2329
_route_resolve_max_turns() { printf '%s' "$_S89_TURNS_SENTINEL"; }
# shellcheck disable=SC2329
_route_resolve_timeout()   { printf '%s' "$_S89_TIMEOUT_SENTINEL"; }

set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
set -e
eval "$_s89_orig_max_turns"
eval "$_s89_orig_timeout"

_s89_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
_s89_turn_block="$(grep -i -A6 "TURN BUDGET" <<< "$_s89_prompt" 2>/dev/null || true)"
if [[ -n "$_s89_turn_block" ]] && grep -q "$_S89_TURNS_SENTINEL" <<< "$_s89_turn_block" \
        && ! grep -q '10' <<< "$_s89_turn_block"; then
    assert_pass "[#1847/SPEC-8] prompt's TURN BUDGET block echoes the _route_resolve_max_turns sentinel (77), not the manifest's max_turns:10"
else
    assert_fail "[#1847/SPEC-8] prompt's TURN BUDGET block must echo the _route_resolve_max_turns sentinel (77), not max_turns:10" \
        "${_s89_turn_block:-absent}"
fi
_s89_wc_block="$(grep -i -A6 "WALL CLOCK BUDGET" <<< "$_s89_prompt" 2>/dev/null || true)"
if [[ -n "$_s89_wc_block" ]] && grep -q "$_S89_TIMEOUT_SENTINEL" <<< "$_s89_wc_block" \
        && ! grep -q '300' <<< "$_s89_wc_block"; then
    assert_pass "[#1847/SPEC-9] prompt's WALL CLOCK BUDGET block echoes the _route_resolve_timeout sentinel (321), not the manifest's timeout_s:300"
else
    assert_fail "[#1847/SPEC-9] prompt's WALL CLOCK BUDGET block must echo the _route_resolve_timeout sentinel (321), not timeout_s:300" \
        "${_s89_wc_block:-absent}"
fi

# ─── SPEC-14: ZBUILD_STAGE_INPUTS-resolved deploy_result/pr_url win over hardcoded paths ─
print_test_section "ZBUILD_STAGE_INPUTS-resolved deploy_result/pr_url content reaches the prompt instead of the artifacts_dir copies"

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
    assert_pass "prompt reflects the ZBUILD_STAGE_INPUTS-resolved deploy_result/pr_url content"
else
    assert_fail "prompt must reflect the ZBUILD_STAGE_INPUTS-resolved deploy_result/pr_url content" \
        "${_s14_prompt:-empty}"
fi
if grep -q "ARTIFACTS_DIR_DECOY" <<< "$_s14_prompt"; then
    assert_fail "prompt must NOT reflect the artifacts_dir decoy when ZBUILD_STAGE_INPUTS is present" \
        "decoy leaked into prompt"
else
    assert_pass "prompt does not reflect the artifacts_dir decoy when ZBUILD_STAGE_INPUTS is present"
fi

# Restore clean artifacts_dir copies (undo the decoy) so later runs in this file
# don't leak stage state.
rm -f "$ARTIFACTS_DIR/deploy-result.json" "$ARTIFACTS_DIR/pr-url.txt"

# ─── SPEC-18: no hardcoded artifacts_dir deploy-result/pr-url construction ───
print_test_section "plugin.sh has no hardcoded artifacts_dir/deploy-result.json or artifacts_dir/pr-url.txt construction"

_s18_grep="$(grep -n 'artifacts_dir.*deploy-result\|artifacts_dir.*pr-url' "$PLUGIN_DIR/plugin.sh" 2>/dev/null || true)"
assert_eq "plugin.sh contains no hardcoded artifacts_dir deploy-result/pr-url construction" \
    "" "$_s18_grep"

print_test_section "ZBUILD_STAGE_INPUTS unset with no entry: treated as not provided, no fallback path is constructed"

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
    assert_fail "prompt must NOT reflect artifacts_dir/deploy-result.json or pr-url.txt content when ZBUILD_STAGE_INPUTS has no entry (no fallback path construction)" \
        "marker leaked into prompt"
else
    assert_pass "with no ZBUILD_STAGE_INPUTS entry, artifacts_dir/deploy-result.json and pr-url.txt content does not reach the prompt"
fi
rm -f "$ARTIFACTS_DIR/deploy-result.json" "$ARTIFACTS_DIR/pr-url.txt"

# ─── SPEC-24 (corrected after review #2221): a turn-budget hit is classified ──
# through the shared _router_rc_classify → router_reason_disposition chokepoint,
# never a hand-written word (the issue: "take it from router_reason_disposition").
# The router reports a budget hit as rc=1 plus its budget marker — it never
# returns 10, so the old dedicated rc=10 branch this SPEC used to assert was dead
# code. Proven by stubbing router_reason_disposition to a sentinel: the written
# disposition must BE the sentinel.
print_test_section "[#1847/SPEC-24] a turn-budget hit (rc=1 + the router's budget marker) is classified through router_reason_disposition"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
_S24_SENTINEL="SENTINEL_ROUTER_REASON_DISPOSITION_CALLED_4e21"
_s24_orig_disposition="$(declare -f router_reason_disposition)"
_s24_orig_route="$(declare -f route_to_model)"
# shellcheck disable=SC2329
router_reason_disposition() {
    if [[ "${1-}" == "router_out_of_turns" ]]; then printf '%s' "$_S24_SENTINEL"; else printf 'unavailable'; fi
}
# shellcheck disable=SC2329
route_to_model() { _router_arm_budget_marker; return 1; }
set +e
ZBUILD_STATE_DIR="$STATE_DIR" ZBUILD_CURRENT_STAGE=monitor monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
_s24_rc=$?
set -e
eval "$_s24_orig_disposition"; eval "$_s24_orig_route"

assert_eq "[#1847/SPEC-24] turn-budget path: monitor_stage_run returns rc=1" "1" "$_s24_rc"
assert_file_exists "[#1847/SPEC-24] monitor-report.json written on the turn-budget path" "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "[#1847/SPEC-24] turn-budget path: disposition comes from router_reason_disposition (the stubbed sentinel)" \
    "$_S24_SENTINEL" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-24] turn-budget path: reason is the classifier's router_out_of_turns" \
    "router_out_of_turns" \
    "$(jq -r '.reason // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"

# ─── SPEC-23: router rc=124 classified through the shared _router_rc_classify ─
# → router_reason_disposition chokepoint, never a hand-copied literal — proven
# by stubbing router_reason_disposition to return a sentinel for argument
# "router_timeout" and asserting the written disposition equals that sentinel,
# not a hardcoded "timed_out" that would pass even if the chokepoint were
# bypassed.
print_test_section "[#1847/SPEC-23] router rc=124 (wall-clock timeout) is classified through the shared _router_rc_classify -> router_reason_disposition chokepoint"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
_S23_SENTINEL="SENTINEL_ROUTER_TIMEOUT_9f3c"
_s23_orig_disposition="$(declare -f router_reason_disposition)"
# shellcheck disable=SC2329
router_reason_disposition() {
    if [[ "${1-}" == "router_timeout" ]]; then
        printf '%s' "$_S23_SENTINEL"
    else
        printf 'unavailable'
    fi
}
MOCK_ROUTE_RC=124
MOCK_ROUTE_RESPONSE=""
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
_s23_rc=$?
set -e
eval "$_s23_orig_disposition"

assert_eq "[#1847/SPEC-23] rc=124 (wall-clock timeout) path: monitor_stage_run returns rc=1 (not the raw router rc=124)" \
    "1" "$_s23_rc"
assert_file_exists "[#1847/SPEC-23] monitor-report.json written on rc=124 path" "$ARTIFACTS_DIR/monitor-report.json"
assert_eq "[#1847/SPEC-23] rc=124 path: disposition equals the router_reason_disposition sentinel, not a hardcoded timed_out" \
    "$_S23_SENTINEL" \
    "$(jq -r '.disposition // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-23] rc=124 path: reason is router_timeout (from _router_rc_classify's own rc=124 case)" \
    "router_timeout" "$(jq -r '.reason // empty' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || true)"

# ─── SPEC-22: template accessor still outranks monitor's own manifest config.router ─
print_test_section "[#1847/SPEC-22] template_stage_router_timeout/max_turns still outrank monitor's manifest config.router (SPEC-7)"

_s22_manifest_timeout="$(awk '/^[[:space:]]*router:/{f=1;next} f&&/timeout_s:/{print $2;exit}' "$MON_MANIFEST" 2>/dev/null || true)"
_s22_manifest_maxturns="$(awk '/^[[:space:]]*router:/{f=1;next} f&&/max_turns:/{print $2;exit}' "$MON_MANIFEST" 2>/dev/null || true)"
# The stub values must diverge from whatever the manifest declares (SPEC-7 adds
# timeout_s:300/max_turns:10) — otherwise a passing assertion could not tell
# "the stub applied" apart from "the manifest applied and happened to match".
if [[ "$_s22_manifest_timeout" == "111" || "$_s22_manifest_maxturns" == "12" ]]; then
    assert_fail "stub values must diverge from the manifest's own config.router" \
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
