#!/usr/bin/env bash
# Tests: deployed.yaml end-to-end dispatch — deploy → validate → monitor (issue #1328-A6)
#
# Verifies the post-PR delivery flow in deployed.yaml:
# SPEC-1: deployed.yaml loads via load_template without error
# SPEC-2: deployed.yaml _TPL_STAGES includes deploy, validate, monitor after pr in order
# SPEC-3: deploy plugin emits plugin.init.start event (ZBUILD_DRY_RUN=1 dispatch)
# SPEC-4: deploy plugin emits plugin.finalize.complete event
# SPEC-5: validate plugin emits plugin.init.start event
# SPEC-6: validate plugin emits plugin.finalize.complete event
# SPEC-7: monitor plugin emits plugin.init.start event
# SPEC-8: monitor plugin emits plugin.finalize.complete event
# SPEC-9: behavior preservation — deploy-result.json verdict=deployed,
#          validate-result.json verdict=healthy, monitor-report.json present
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "deployed.yaml e2e — deploy+validate+monitor dry-run dispatch (#1328-A6)"
setup_test_env "deployed-template-e2e"
_test_cleanup_hook() { cleanup_test_env; }

STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
EVENTS_DIR="$TEST_TEMP_DIR/events"
EVENTS_JSONL="$EVENTS_DIR/events.jsonl"

export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_RUN_ID="deployed-e2e-$$"
export ZBUILD_ISSUE="1328"
export ZBUILD_DRY_RUN=1
export NO_GITHUB=true
export ZBUILD_OUTPUT_GH_COMMENT=0
export ZBUILD_OUTPUT_GH_CHECK_RUN=0

mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR" "$EVENTS_DIR"

# ─── SPEC-1: deployed.yaml loads without error ────────────────────────────────
# CHANGE: deployed.yaml did not exist at merge-base → load_template returned
# non-zero. Now it must return 0.

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/template-resolver.sh
source "$REPO_ROOT/core/pipeline/template-resolver.sh"

DEPLOYED_TPL="$REPO_ROOT/config/templates/deployed.yaml"

set +e
load_template "$DEPLOYED_TPL"
_load_rc=$?
set -e

assert_eq "[SPEC-1] deployed.yaml loads without error (exit 0)" "0" "$_load_rc"

# ─── SPEC-2: _TPL_STAGES includes deploy, validate, monitor after pr ──────────
# CHANGE: deployed.yaml did not exist → these stages were absent.

_has_deploy=0; _has_validate=0; _has_monitor=0
_pr_idx=-1; _deploy_idx=-1; _validate_idx=-1; _monitor_idx=-1
for _i in "${!_TPL_STAGES[@]}"; do
    case "${_TPL_STAGES[$_i]}" in
        pr)       _pr_idx=$_i ;;
        deploy)   _has_deploy=1; _deploy_idx=$_i ;;
        validate) _has_validate=1; _validate_idx=$_i ;;
        monitor)  _has_monitor=1; _monitor_idx=$_i ;;
    esac
done

assert_eq "[SPEC-2] deployed.yaml has deploy stage" "1" "$_has_deploy"
assert_eq "[SPEC-2] deployed.yaml has validate stage" "1" "$_has_validate"
assert_eq "[SPEC-2] deployed.yaml has monitor stage" "1" "$_has_monitor"
# Verify ordering: pr < deploy < validate < monitor
if [[ "$_pr_idx" -ge 0 && "$_deploy_idx" -ge 0 && "$_validate_idx" -ge 0 && "$_monitor_idx" -ge 0 ]]; then
    assert_eq "[SPEC-2] deploy follows pr" "1" "$(( _deploy_idx > _pr_idx ? 1 : 0 ))"
    assert_eq "[SPEC-2] validate follows deploy" "1" "$(( _validate_idx > _deploy_idx ? 1 : 0 ))"
    assert_eq "[SPEC-2] monitor follows validate" "1" "$(( _monitor_idx > _validate_idx ? 1 : 0 ))"
else
    assert_fail "[SPEC-2] pr/deploy/validate/monitor stage indices resolved" \
        "pr=$_pr_idx deploy=$_deploy_idx validate=$_validate_idx monitor=$_monitor_idx"
fi

# ─── Initialize state file ────────────────────────────────────────────────────
STATE_FILE="$STATE_DIR/pipeline-state.json"
jq -n \
    --arg run_id "$ZBUILD_RUN_ID" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1, run_id:$run_id, issue:1328, stage_statuses:{},
      current_iteration:0, self_heal_count:{}, scope_manifest_hash:"",
      cost_ledger_pointer:0, claim_lease_id:"", plugin_state:{},
      updated_at:$now}' > "$STATE_FILE"

# Write pr-url.txt prerequisite (deploy requires it from the pr stage)
printf 'https://github.com/example/repo/pull/42\n' > "$ARTIFACTS_DIR/pr-url.txt"

# Write a mock gate-aggregator-result.json (deploy reads it in non-dry-run;
# in dry-run mode deploy writes sentinel without reading the gate file, so this
# is purely for completeness)
jq -n '{schema_version:1,verdict:"pass"}' > "$ARTIFACTS_DIR/gate-aggregator-result.json"

# ─── SPEC-3 + SPEC-4 + SPEC-9 (deploy): init → run → finalize ───────────────
# CHANGE: before #1328 wiring, no template carried the deploy stage; plugin.init.start
# and plugin.finalize.complete were never emitted in a template-dispatched flow.

# Source the deploy plugin (guard prevents double-load across sourced files)
# shellcheck source=../../plugins/agent/deploy/plugin.sh
source "$REPO_ROOT/plugins/agent/deploy/plugin.sh"

set +e
deploy_agent_init
_init_rc=$?
set -e
assert_eq "[SPEC-3] deploy_agent_init exits 0" "0" "$_init_rc"
assert_event_emitted "[SPEC-3] deploy emits plugin.init.start" "$EVENTS_JSONL" "plugin.init.start"

set +e
deploy_agent_run "deploy" "$STATE_FILE"
_run_rc=$?
set -e
assert_eq "[SPEC-9] deploy_agent_run exits 0 in dry-run" "0" "$_run_rc"

set +e
deploy_agent_finalize
_fin_rc=$?
set -e
assert_eq "[SPEC-4] deploy_agent_finalize exits 0" "0" "$_fin_rc"
assert_event_emitted "[SPEC-4] deploy emits plugin.finalize.complete" "$EVENTS_JSONL" "plugin.finalize.complete"

# Behavior-preservation: deploy-result.json exists and carries verdict=deployed
assert_file_exists "[SPEC-9] deploy-result.json written" "$ARTIFACTS_DIR/deploy-result.json"
_deploy_verdict="$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/deploy-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-9] deploy-result.json verdict=deployed" "deployed" "$_deploy_verdict"

# ─── SPEC-5 + SPEC-6 + SPEC-9 (validate): init → run → finalize ─────────────
# CHANGE: before #1328 wiring, no template carried the validate stage.

# Source the validate plugin
# shellcheck source=../../plugins/agent/validate/plugin.sh
source "$REPO_ROOT/plugins/agent/validate/plugin.sh"

# Clear event counters between stages by noting prior event count; use grep-count approach
_events_before_validate="$(wc -l < "$EVENTS_JSONL" 2>/dev/null || echo 0)"

set +e
validate_agent_init
_init_rc=$?
set -e
assert_eq "[SPEC-5] validate_agent_init exits 0" "0" "$_init_rc"
assert_event_emitted "[SPEC-5] validate emits plugin.init.start" "$EVENTS_JSONL" "plugin.init.start"

set +e
validate_agent_run "validate" "$STATE_FILE"
_run_rc=$?
set -e
assert_eq "[SPEC-9] validate_agent_run exits 0 in dry-run" "0" "$_run_rc"

set +e
validate_agent_finalize
_fin_rc=$?
set -e
assert_eq "[SPEC-6] validate_agent_finalize exits 0" "0" "$_fin_rc"
assert_event_emitted "[SPEC-6] validate emits plugin.finalize.complete" "$EVENTS_JSONL" "plugin.finalize.complete"

# Behavior-preservation: validate-result.json exists and carries verdict=healthy
assert_file_exists "[SPEC-9] validate-result.json written" "$ARTIFACTS_DIR/validate-result.json"
_validate_verdict="$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/validate-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-9] validate-result.json verdict=healthy" "healthy" "$_validate_verdict"

# ─── SPEC-7 + SPEC-8 + SPEC-9 (monitor): init → run → finalize ──────────────
# CHANGE: before #1328 wiring, no template carried the monitor stage.

# Source the monitor plugin
# shellcheck source=../../plugins/agent/monitor/plugin.sh
source "$REPO_ROOT/plugins/agent/monitor/plugin.sh"

set +e
monitor_stage_init
_init_rc=$?
set -e
assert_eq "[SPEC-7] monitor_stage_init exits 0" "0" "$_init_rc"
assert_event_emitted "[SPEC-7] monitor emits plugin.init.start" "$EVENTS_JSONL" "plugin.init.start"

set +e
monitor_stage_run "monitor" "$STATE_FILE"
_run_rc=$?
set -e
assert_eq "[SPEC-9] monitor_stage_run exits 0 in dry-run" "0" "$_run_rc"

set +e
monitor_stage_finalize
_fin_rc=$?
set -e
assert_eq "[SPEC-8] monitor_stage_finalize exits 0" "0" "$_fin_rc"
assert_event_emitted "[SPEC-8] monitor emits plugin.finalize.complete" "$EVENTS_JSONL" "plugin.finalize.complete"

# Behavior-preservation: monitor-report.json exists
assert_file_exists "[SPEC-9] monitor-report.json written" "$ARTIFACTS_DIR/monitor-report.json"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
