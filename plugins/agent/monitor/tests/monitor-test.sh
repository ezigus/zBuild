#!/usr/bin/env bash
# Tests: plugins/agent/monitor — monitor stage agent (issue #758)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: monitor (kind:agent, one-shot health assessment — issue #758)"

setup_test_env "plugin-monitor"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export ZBUILD_RUN_ID="monitor-test-$$"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/monitor"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"

# ─── State dir fixture ────────────────────────────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
export ZBUILD_ARTIFACT_DIR="$STATE_DIR/artifacts"   # the engine names the output dir (review #2221)
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
printf '{"schema_version":1,"run_id":"test","issue":"758","stage_statuses":{}}\n' > "$STATE_FILE"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ plugins/
+ core/
SCOPE

# ─── Source plugin under test ─────────────────────────────────────────────────
# shellcheck source=../../../../plugins/agent/monitor/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Mock: route_to_model — file-based capture + configurable rc/response ─────
# (No apply_scope_redaction mock: the plugin no longer pre-redacts — route_to_model
#  owns redaction by construction, ADR-043, and it is mocked here.)
_CAPTURED_PROMPT_FILE="$TEST_TEMP_DIR/captured-monitor-prompt.txt"
: > "$_CAPTURED_PROMPT_FILE"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"deployment healthy","checks":[]}'
_ROUTE_TO_MODEL_CALLED=0

route_to_model() {
    _ROUTE_TO_MODEL_CALLED=$((_ROUTE_TO_MODEL_CALLED + 1))
    # Capture the prompt (arg $2) to a file
    printf '%s' "${2:-}" > "$_CAPTURED_PROMPT_FILE"
    if [[ "$MOCK_ROUTE_RC" -eq 0 ]]; then
        printf '%s\n' "$MOCK_ROUTE_RESPONSE"
    fi
    return "$MOCK_ROUTE_RC"
}

# ─── [SPEC-2] ZBUILD_DRY_RUN=1 writes mock artifacts without route_to_model ──
print_test_section "[SPEC-2] dry-run writes mock monitor-report.json (verdict embedded) without route_to_model"

_ROUTE_TO_MODEL_CALLED=0
export ZBUILD_DRY_RUN=1

set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
rc_dry=$?
set -e
unset ZBUILD_DRY_RUN

assert_eq "[SPEC-2] dry-run run returns rc=0" "0" "$rc_dry"
assert_file_exists "[SPEC-2] monitor-report.json created in dry-run" \
    "$ARTIFACTS_DIR/monitor-report.json"

_dry_report_verdict="$(jq -r '.verdict // "missing"' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || echo 'error')"
assert_eq "[SPEC-2] dry-run monitor-report.json has .verdict=pass (embedded)" \
    "pass" "$_dry_report_verdict"
assert_eq "[SPEC-2] dry-run does NOT call route_to_model" \
    "0" "$_ROUTE_TO_MODEL_CALLED"

# Reset artifacts for live-run tests
rm -f "$ARTIFACTS_DIR/monitor-report.json"

# ─── [SPEC-3] live run (mocked rc=0) produces monitor-report.json + verdict ───
print_test_section "[SPEC-3] live run: mocked route_to_model rc=0 → monitor-report.json with .verdict=pass"

cp "$FIXTURE_DIR/deploy-result.json" "$ARTIFACTS_DIR/deploy-result.json"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"deployment healthy","checks":[]}'
_ROUTE_TO_MODEL_CALLED=0

set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
rc_live=$?
set -e

assert_eq "[SPEC-3] live run returns rc=0" "0" "$rc_live"
assert_file_exists "[SPEC-3] monitor-report.json created" "$ARTIFACTS_DIR/monitor-report.json"

_live_verdict="$(jq -r '.verdict // "missing"' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || echo 'error')"
assert_eq "[SPEC-3] monitor-report.json .verdict=pass on healthy response" \
    "pass" "$_live_verdict"

# [SPEC-3] robustness: a model that appends a bare {"verdict":"pass"} after a full
# degraded report MUST NOT self-report pass — the schema-gated envelope recovery
# keeps the single object that matches the full contract (degraded).
rm -f "$ARTIFACTS_DIR/monitor-report.json"
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"degraded","summary":"probe failed","checks":[]}
Actually, final verdict: {"verdict":"pass"}'
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
set -e
_selfreport_verdict="$(jq -r '.verdict // "missing"' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || echo 'error')"
assert_eq "[SPEC-3] appended bare pass object does NOT override the full report" \
    "degraded" "$_selfreport_verdict"

# ─── [SPEC-4] model error → primary monitor-report.json (degraded) still written + non-zero rc ──
print_test_section "[SPEC-4] route_to_model failure → primary monitor-report.json (degraded) STILL written, non-zero rc"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
MOCK_ROUTE_RC=1
MOCK_ROUTE_RESPONSE=""
_ROUTE_TO_MODEL_CALLED=0

set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
rc_fail=$?
set -e

# The primary/required artifact MUST exist on EVERY exit path (ADR-047 §3,
# artifact contract) — this is the correctness gap the review flagged.
assert_file_exists "[SPEC-4] monitor-report.json (primary) written on model error" \
    "$ARTIFACTS_DIR/monitor-report.json"
_fail_verdict="$(jq -r '.verdict // "missing"' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || echo 'error')"
assert_eq "[SPEC-4] monitor-report.json .verdict=degraded on model error" \
    "degraded" "$_fail_verdict"
if [[ "$rc_fail" -ne 0 ]]; then
    assert_pass "[SPEC-4] plugin returns non-zero rc on model error (rc=$rc_fail)"
else
    assert_fail "[SPEC-4] plugin should return non-zero rc on model error"
fi

# ─── [SPEC-6] the monitor manifest declares its own monitor.* events ─────────
# #1717: monitor.* are the monitor plugin's events, so they live in the plugin's
# own manifest (provides.events) and reach the known set through composition,
# not through the engine's config/event-schema.json. Both legs are asserted: the
# declaration (ownership) and the composed set (the engine actually sees it).
print_test_section "[SPEC-6] monitor's manifest declares monitor.started, monitor.check, monitor.alert"

_manifest_file="$REPO_ROOT/plugins/agent/monitor/manifest.yaml"
assert_file_exists "[SPEC-6] monitor manifest exists" "$_manifest_file"

# shellcheck source=../../../../core/event-bus/known-types.sh
source "$REPO_ROOT/core/event-bus/known-types.sh"
_declared_events="$(eb_manifest_events "$_manifest_file")"
_composed_events="$(eb_compose_known_types)"

for _ev in monitor.started monitor.check monitor.alert; do
    if grep -qxF "$_ev" <<< "$_declared_events"; then
        assert_pass "[SPEC-6] manifest declares $_ev under provides.events"
    else
        assert_fail "[SPEC-6] manifest declares $_ev under provides.events" \
            "absent from $_manifest_file"
    fi
    if grep -qxF "$_ev" <<< "$_composed_events"; then
        assert_pass "[SPEC-6] $_ev is in the composed known set"
    else
        assert_fail "[SPEC-6] $_ev is in the composed known set" \
            "composition (engine config + manifests) did not yield it"
    fi
done

# ─── [SPEC-7] validate_manifest passes on manifest.yaml ──────────────────────
print_test_section "[SPEC-7] validate_manifest passes on plugins/agent/monitor/manifest.yaml"

_ZBUILD_MANIFEST_VALIDATION_LOADED=""
# shellcheck source=../../../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"

set +e
validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1
rc_manifest=$?
set -e

assert_eq "[SPEC-7] validate_manifest returns rc=0 for monitor manifest.yaml" \
    "0" "$rc_manifest"

# ─── [SPEC-8] manifest declares id=monitor, kind=agent, tier T1 ──────────────
print_test_section "[SPEC-8] manifest.yaml has id=monitor, kind=agent, tier_default=T1"

_manifest_id="$(yaml_get "$PLUGIN_DIR/manifest.yaml" "id" 2>/dev/null || echo '')"
assert_eq "[SPEC-8] manifest id=monitor" "monitor" "$_manifest_id"

_manifest_kind="$(yaml_get "$PLUGIN_DIR/manifest.yaml" "kind" 2>/dev/null || echo '')"
assert_eq "[SPEC-8] manifest kind=agent" "agent" "$_manifest_kind"

_manifest_tier="$(yaml_get "$PLUGIN_DIR/manifest.yaml" "config.tier_default" 2>/dev/null || echo '')"
assert_eq "[SPEC-8] manifest config.tier_default=T1" "T1" "$_manifest_tier"

# ─── [SPEC-9] plugin.sh has legacy-citation comment ──────────────────────────
print_test_section "[SPEC-9] plugin.sh contains legacy-citation for pipeline-stages-monitor.sh:150"

if grep -q "pipeline-stages-monitor.sh:150" "$PLUGIN_DIR/plugin.sh"; then
    assert_pass "[SPEC-9] plugin.sh contains legacy-citation pipeline-stages-monitor.sh:150"
else
    assert_fail "[SPEC-9] plugin.sh missing legacy-citation pipeline-stages-monitor.sh:150"
fi

# ═══════════════════════════════════════════════════════════════════════════
# #1847 (Phase 0/F: migrate monitor to contract v2) — guard assertions
# ═══════════════════════════════════════════════════════════════════════════

# ─── [#1847/SPEC-10] ZBUILD_DRY_RUN=1 still returns rc=0, verdict=pass, no route_to_model ─
print_test_section "[#1847/SPEC-10] ZBUILD_DRY_RUN=1 still returns rc=0 and writes verdict=pass without calling route_to_model"

rm -f "$ARTIFACTS_DIR/monitor-report.json"
_ROUTE_TO_MODEL_CALLED=0
export ZBUILD_DRY_RUN=1

set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
_s1847_10_rc=$?
set -e
unset ZBUILD_DRY_RUN

assert_eq "[#1847/SPEC-10] dry-run still returns rc=0" "0" "$_s1847_10_rc"
assert_eq "[#1847/SPEC-10] dry-run still does NOT call route_to_model" "0" "$_ROUTE_TO_MODEL_CALLED"
_s1847_10_verdict="$(jq -r '.verdict // "missing"' "$ARTIFACTS_DIR/monitor-report.json" 2>/dev/null || echo 'error')"
assert_eq "[#1847/SPEC-10] dry-run still writes verdict=pass" "pass" "$_s1847_10_verdict"

# ─── [#1847/SPEC-11] config.valid_verdicts remains exactly [pass, degraded] ──
print_test_section "[#1847/SPEC-11] config.valid_verdicts remains exactly [pass, degraded]"

_s1847_11_stanza="$(awk '
    /^[[:space:]]*valid_verdicts:/ { f=1; next }
    f && /^[[:space:]]*-[[:space:]]/ { print; next }
    f { exit }
' "$PLUGIN_DIR/manifest.yaml" 2>/dev/null || true)"
_s1847_11_count="$(grep -c '^[[:space:]]*-[[:space:]]' <<< "$_s1847_11_stanza" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-11] manifest valid_verdicts has exactly 2 entries" "2" "$_s1847_11_count"
if grep -qx '[[:space:]]*- pass' <<< "$_s1847_11_stanza" && grep -qx '[[:space:]]*- degraded' <<< "$_s1847_11_stanza"; then
    assert_pass "[#1847/SPEC-11] manifest valid_verdicts is exactly [pass, degraded]"
else
    assert_fail "[#1847/SPEC-11] manifest valid_verdicts is exactly [pass, degraded]" "${_s1847_11_stanza:-absent}"
fi

# ─── [#1847/SPEC-12] inputs: still declares only deploy_result/pr_url, required:false ─
print_test_section "[#1847/SPEC-12] inputs: still declares only deploy_result and pr_url, both required:false, no restated source/path/type"

_s1847_12_inputs="$(awk '
    /^inputs:/ { f=1; next }
    f && /^[a-zA-Z]/ { exit }
    f { print }
' "$PLUGIN_DIR/manifest.yaml" 2>/dev/null || true)"
_s1847_12_id_count="$(grep -c '^[[:space:]]*-[[:space:]]*id:' <<< "$_s1847_12_inputs" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-12] inputs: declares exactly 2 input ids" "2" "$_s1847_12_id_count"
_s1847_12_required_false="$(grep -c 'required:[[:space:]]*false' <<< "$_s1847_12_inputs" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-12] inputs: both entries have required:false" "2" "$_s1847_12_required_false"
_s1847_12_restated="$(grep -cE '^\s*(source|path|type):' <<< "$_s1847_12_inputs" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-12] inputs: no restated source/path/type keys" "0" "$_s1847_12_restated"

# ─── [#1847/SPEC-17] provides.events unchanged; plugin.sh still emits all three ─
print_test_section "[#1847/SPEC-17] manifest still declares provides.events [monitor.alert, monitor.check, monitor.started]; plugin.sh still emits all three"

for _ev in monitor.started monitor.check monitor.alert; do
    if grep -qxF "$_ev" <<< "$_declared_events"; then
        assert_pass "[#1847/SPEC-17] manifest still declares $_ev under provides.events"
    else
        assert_fail "[#1847/SPEC-17] manifest still declares $_ev under provides.events" \
            "absent from $_manifest_file"
    fi
    if grep -q "emit_event \"$_ev\"" "$PLUGIN_DIR/plugin.sh"; then
        assert_pass "[#1847/SPEC-17] plugin.sh still emits $_ev"
    else
        assert_fail "[#1847/SPEC-17] plugin.sh still emits $_ev" "no emit_event \"$_ev\" call found"
    fi
done

# ─── [#1847/SPEC-18] ZBUILD_STAGE_INPUTS-resolved deploy_result/pr_url reach the ─
# prompt; no hardcoded $artifacts_dir/deploy-result.json / pr-url.txt fallback ─
print_test_section "[#1847/SPEC-18] deploy_result/pr_url are read via ZBUILD_STAGE_INPUTS — no hardcoded artifacts_dir fallback remains"

unset ZBUILD_STAGE_INPUTS 2>/dev/null || true
rm -f "$ARTIFACTS_DIR/monitor-report.json"
cp "$FIXTURE_DIR/deploy-result.json" "$ARTIFACTS_DIR/deploy-result.json"
printf 'https://github.com/mock/repo/pull/1847\n' > "$ARTIFACTS_DIR/pr-url.txt"
_s1847_18_si="$TEST_TEMP_DIR/stage-inputs.json"
printf '{"inputs":{"deploy_result":"%s","pr_url":"%s"}}\n' \
    "$ARTIFACTS_DIR/deploy-result.json" "$ARTIFACTS_DIR/pr-url.txt" > "$_s1847_18_si"
MOCK_ROUTE_RC=0
MOCK_ROUTE_RESPONSE='{"schema_version":1,"verdict":"pass","summary":"deployment healthy","checks":[]}'
_ROUTE_TO_MODEL_CALLED=0

set +e
( export ZBUILD_STAGE_INPUTS="$_s1847_18_si"; monitor_stage_run "monitor" "$STATE_FILE" ) >/dev/null 2>&1
_s1847_18_rc=$?
set -e

assert_eq "[#1847/SPEC-18] ZBUILD_STAGE_INPUTS-resolved run returns rc=0" "0" "$_s1847_18_rc"
_s1847_18_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -q "test-branch" <<< "$_s1847_18_prompt"; then
    assert_pass "[#1847/SPEC-18] prompt reflects the ZBUILD_STAGE_INPUTS-resolved deploy_result content"
else
    assert_fail "[#1847/SPEC-18] prompt reflects the ZBUILD_STAGE_INPUTS-resolved deploy_result content" \
        "${_s1847_18_prompt:-empty}"
fi
if grep -q "pull/1847" <<< "$_s1847_18_prompt"; then
    assert_pass "[#1847/SPEC-18] prompt reflects the ZBUILD_STAGE_INPUTS-resolved pr_url content"
else
    assert_fail "[#1847/SPEC-18] prompt reflects the ZBUILD_STAGE_INPUTS-resolved pr_url content" \
        "${_s1847_18_prompt:-empty}"
fi

# The static guard from the SPEC text itself: no hardcoded
# $artifacts_dir/deploy-result.json or $artifacts_dir/pr-url.txt string
# construction anywhere in plugin.sh.
_s1847_18_hardcoded="$(grep -n 'artifacts_dir.*deploy-result\|artifacts_dir.*pr-url' "$PLUGIN_DIR/plugin.sh" 2>/dev/null || true)"
assert_eq "[#1847/SPEC-18] plugin.sh contains no hardcoded artifacts_dir deploy-result/pr-url construction" \
    "" "$_s1847_18_hardcoded"

# With ZBUILD_STAGE_INPUTS unset and no entry for either optional input, the
# plugin must treat them as not provided rather than falling back to the
# artifacts_dir copies (which are decoyed here to prove the fallback is gone).
rm -f "$ARTIFACTS_DIR/monitor-report.json"
unset ZBUILD_STAGE_INPUTS 2>/dev/null || true
printf '{"decoy":true,"marker":"MONITOR_TEST_NO_FALLBACK_MARKER"}\n' > "$ARTIFACTS_DIR/deploy-result.json"
printf 'https://example.com/MONITOR_TEST_NO_FALLBACK_MARKER\n' > "$ARTIFACTS_DIR/pr-url.txt"
: > "$_CAPTURED_PROMPT_FILE"
set +e
monitor_stage_run "monitor" "$STATE_FILE" >/dev/null 2>&1
set -e
_s1847_18_nofallback_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -q "MONITOR_TEST_NO_FALLBACK_MARKER" <<< "$_s1847_18_nofallback_prompt"; then
    assert_fail "[#1847/SPEC-18] with no ZBUILD_STAGE_INPUTS entry, the artifacts_dir copies must NOT reach the prompt (no fallback path)" \
        "marker leaked into prompt"
else
    assert_pass "[#1847/SPEC-18] with no ZBUILD_STAGE_INPUTS entry, deploy_result/pr_url are treated as not provided"
fi
rm -f "$ARTIFACTS_DIR/deploy-result.json" "$ARTIFACTS_DIR/pr-url.txt"

# ─── cleanup + results ────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
