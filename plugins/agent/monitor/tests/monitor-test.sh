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

# ─── [SPEC-6] config/event-schema.json registers monitor.* events ─────────────
print_test_section "[SPEC-6] event-schema.json registers monitor.started, monitor.check, monitor.alert"

_schema_file="$REPO_ROOT/config/event-schema.json"
assert_file_exists "[SPEC-6] event-schema.json exists" "$_schema_file"

_schema_has_started="$(jq -r 'if (.known_types | index("monitor.started")) then "yes" else "no" end' "$_schema_file" 2>/dev/null || echo 'error')"
assert_eq "[SPEC-6] event-schema.json registers monitor.started" \
    "yes" "$_schema_has_started"

_schema_has_check="$(jq -r 'if (.known_types | index("monitor.check")) then "yes" else "no" end' "$_schema_file" 2>/dev/null || echo 'error')"
assert_eq "[SPEC-6] event-schema.json registers monitor.check" \
    "yes" "$_schema_has_check"

_schema_has_alert="$(jq -r 'if (.known_types | index("monitor.alert")) then "yes" else "no" end' "$_schema_file" 2>/dev/null || echo 'error')"
assert_eq "[SPEC-6] event-schema.json registers monitor.alert" \
    "yes" "$_schema_has_alert"

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

# ─── cleanup + results ────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
