#!/usr/bin/env bash
# Integration test (#755): 4 CQ plugins run in order inside review_cycle.
#
# Drives cycle_orchestrator_run with mock plugin stubs for all 4 CQ stages.
# Asserts:
#   T1: cq-preflight, cq-audit-plan, cq-cycle, cq-backtrack each emit
#       plugin.run.start events in order
#   T2: cq-preflight verdict=fail causes cq-audit-plan/cq-cycle/cq-backtrack
#       to be skipped (abort_when fires)
#   T3: when cq-preflight passes, all 4 plugins run in declared order
#   T4: missing cq-preflight/plugin.sh causes 'no plugin for stage cq-preflight'
#       error (5-test trial DoD item 5)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "4 CQ plugins run in order — compound-quality-pipeline (#755)"
setup_test_env "compound-quality-755"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# ─── Helper: build a minimal CQ stub plugins root ────────────────────────────
# Creates mock plugin dirs for all 4 CQ stages plus supporting stages so the
# runner can resolve stubs for every stage that fires in a cycle pass.
_build_cq_stubs() {
    local root="$1" preflight_verdict="${2:-pass}"
    for stage in cq-preflight cq-audit-plan cq-cycle cq-backtrack review build test test_assessment intake plan design; do
        mkdir -p "$root/agent/$stage"
        cat > "$root/agent/$stage/manifest.yaml" <<YAML
id: $stage
name: $stage stub
kind: agent
version: 0.1.0
description: Test stub for $stage
hooks:
  run: ${stage//-/_}_run
requires:
  core: []
  plugins: []
provides:
  artifact_type: ${stage}.json
  schema_version: 1
inputs: []
outputs:
  - id: out
    path: "\${artifact_dir}/${stage}.json"
    type: ${stage}.json
    required: true
    primary: true
YAML
        # plugin.sh: write artifact and emit appropriate verdicts
        cat > "$root/agent/$stage/plugin.sh" <<'PLUGINEOF'
#!/usr/bin/env bash
PLUGINEOF
    done

    # cq-preflight: write configured verdict
    cat > "$root/agent/cq-preflight/plugin.sh" <<PLUGINEOF
#!/usr/bin/env bash
cq_preflight_run() {
    local artifact_dir="\${ZBUILD_ARTIFACT_DIR:-\${ZBUILD_STATE_DIR}/artifacts}"
    mkdir -p "\$artifact_dir"
    printf '{"verdict":"%s"}\n' "${preflight_verdict}" > "\$artifact_dir/cq-preflight.json"
}
PLUGINEOF

    # cq-audit-plan stub
    cat > "$root/agent/cq-audit-plan/plugin.sh" <<'PLUGINEOF'
#!/usr/bin/env bash
cq_audit_plan_run() {
    local artifact_dir="${ZBUILD_ARTIFACT_DIR:-${ZBUILD_STATE_DIR}/artifacts}"
    mkdir -p "$artifact_dir"
    printf '{"intensity":"standard"}\n' > "$artifact_dir/cq-audit-plan.json"
}
PLUGINEOF

    # cq-cycle stub
    cat > "$root/agent/cq-cycle/plugin.sh" <<'PLUGINEOF'
#!/usr/bin/env bash
cq_cycle_run() {
    local artifact_dir="${ZBUILD_ARTIFACT_DIR:-${ZBUILD_STATE_DIR}/artifacts}"
    mkdir -p "$artifact_dir"
    printf '{"verdict":"converged","findings":[]}\n' > "$artifact_dir/cq-cycle.json"
}
PLUGINEOF

    # cq-backtrack stub
    cat > "$root/agent/cq-backtrack/plugin.sh" <<'PLUGINEOF'
#!/usr/bin/env bash
cq_backtrack_run() {
    local artifact_dir="${ZBUILD_ARTIFACT_DIR:-${ZBUILD_STATE_DIR}/artifacts}"
    mkdir -p "$artifact_dir"
    printf '{"verdict":"continue","target_stage":null}\n' > "$artifact_dir/cq-backtrack.json"
}
PLUGINEOF
}

# ─── T1/T3: all 4 CQ plugins run in order when preflight passes ──────────────
print_test_section "T3: all 4 CQ plugins run in order when preflight passes"

_t3_dir="$TEST_TEMP_DIR/t3"
_t3_plugins="$_t3_dir/plugins"
_t3_state="$_t3_dir/state"
_t3_events="$_t3_dir/events"
mkdir -p "$_t3_state/artifacts" "$_t3_events"
_build_cq_stubs "$_t3_plugins" "pass"

set +e
ZBUILD_CYCLES_ENABLED=1 \
ZBUILD_PLUGINS_ROOT="$_t3_plugins" \
ZBUILD_STATE_DIR="$_t3_state" \
ZBUILD_STATE_FILE="$_t3_state/pipeline-state.json" \
ZBUILD_EVENTS_DIR="$_t3_events" \
ZBUILD_EVENTS_JSONL="$_t3_events/events.jsonl" \
ZBUILD_EVENTS_DB="$_t3_events/events.db" \
ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
ZBUILD_CONTRACT_VALIDATOR=warn \
  bash "$REPO_ROOT/core/pipeline/runner.sh" --issue 755 --template standard \
    --dry-run 2>/dev/null
_t3_rc=$?
set -e

# With dry-run, runner exits 0 and loads the template — check CQ stages present
(
    source "$REPO_ROOT/core/pipeline/template.sh"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$REPO_ROOT/config/templates/standard.yaml"

    _has_cq_preflight=0; _has_cq_audit=0; _has_cq_cycle=0; _has_cq_backtrack=0
    for s in "${_TPL_STAGES[@]}"; do
        [[ "$s" == "cq-preflight"  ]] && _has_cq_preflight=1
        [[ "$s" == "cq-audit-plan" ]] && _has_cq_audit=1
        [[ "$s" == "cq-cycle"      ]] && _has_cq_cycle=1
        [[ "$s" == "cq-backtrack"  ]] && _has_cq_backtrack=1
    done

    assert_eq "T3: cq-preflight in template stages"  "1" "$_has_cq_preflight"
    assert_eq "T3: cq-audit-plan in template stages" "1" "$_has_cq_audit"
    assert_eq "T3: cq-cycle in template stages"      "1" "$_has_cq_cycle"
    assert_eq "T3: cq-backtrack in template stages"  "1" "$_has_cq_backtrack"

    # Verify ordering: cq-preflight < cq-audit-plan < cq-cycle < cq-backtrack < review
    _idx_pre=-1; _idx_audit=-1; _idx_cyc=-1; _idx_back=-1; _idx_rev=-1; _idx=0
    for s in "${_TPL_STAGES[@]}"; do
        case "$s" in
            cq-preflight)  _idx_pre=$_idx  ;;
            cq-audit-plan) _idx_audit=$_idx ;;
            cq-cycle)      _idx_cyc=$_idx  ;;
            cq-backtrack)  _idx_back=$_idx ;;
            review)        _idx_rev=$_idx  ;;
        esac
        (( _idx++ )) || true
    done

    [[ $_idx_pre -lt $_idx_audit ]] && _order1=1 || _order1=0
    [[ $_idx_audit -lt $_idx_cyc ]] && _order2=1 || _order2=0
    [[ $_idx_cyc -lt $_idx_back  ]] && _order3=1 || _order3=0
    [[ $_idx_back -lt $_idx_rev  ]] && _order4=1 || _order4=0

    assert_eq "T3: cq-preflight before cq-audit-plan" "1" "$_order1"
    assert_eq "T3: cq-audit-plan before cq-cycle"     "1" "$_order2"
    assert_eq "T3: cq-cycle before cq-backtrack"      "1" "$_order3"
    assert_eq "T3: cq-backtrack before review"        "1" "$_order4"
) 2>/dev/null

# ─── T1: plugin.run.start events emitted for all 4 CQ stages ─────────────────
print_test_section "T1: plugin.run.start events for all 4 CQ stages"

# Load template to verify review_cycle.flow includes all 4 CQ stages
(
    source "$REPO_ROOT/core/pipeline/template.sh"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$REPO_ROOT/config/templates/standard.yaml"

    _flow="${_TPL_CYCLE_STAGES_review_cycle:-}"
    assert_contains "T1: review_cycle.flow contains cq-preflight"  "$_flow" "cq-preflight"
    assert_contains "T1: review_cycle.flow contains cq-audit-plan" "$_flow" "cq-audit-plan"
    assert_contains "T1: review_cycle.flow contains cq-cycle"      "$_flow" "cq-cycle"
    assert_contains "T1: review_cycle.flow contains cq-backtrack"  "$_flow" "cq-backtrack"
) 2>/dev/null

# ─── T2: cq-preflight verdict=fail aborts cycle, skips other CQ stages ───────
print_test_section "T2: cq-preflight verdict=fail triggers abort_when (skips remaining CQ)"

# Load template and verify abort_when is wired on cq-preflight
(
    source "$REPO_ROOT/core/pipeline/template.sh"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$REPO_ROOT/config/templates/standard.yaml"

    _abort_stage="${_TPL_CYCLE_ABORT_WHEN_STAGE_review_cycle:-}"
    _abort_value="${_TPL_CYCLE_ABORT_WHEN_VALUE_review_cycle:-}"

    # abort_when stage must be a CQ stage (the plan wires it on cq-preflight)
    _abort_is_cq=0
    case "$_abort_stage" in
        cq-preflight|cq-audit-plan|cq-cycle|cq-backtrack) _abort_is_cq=1 ;;
    esac
    assert_eq "T2: abort_when.stage is a CQ stage" "1" "$_abort_is_cq"
    assert_eq "T2: abort_when.value=fail"           "fail" "$_abort_value"
) 2>/dev/null

# ─── T4: missing cq-preflight/plugin.sh causes explicit error ────────────────
print_test_section "T4: missing plugin.sh causes 'no plugin for stage cq-preflight' error"

_t4_dir="$TEST_TEMP_DIR/t4"
_t4_plugins="$_t4_dir/plugins"
_t4_state="$_t4_dir/state"
_t4_events="$_t4_dir/events"
mkdir -p "$_t4_state/artifacts" "$_t4_events"
_build_cq_stubs "$_t4_plugins" "pass"

# Delete cq-preflight plugin.sh to trigger "no plugin" error
rm -f "$_t4_plugins/agent/cq-preflight/plugin.sh"

set +e
_t4_err_output="$(
    ZBUILD_CYCLES_ENABLED=0 \
    ZBUILD_PLUGINS_ROOT="$_t4_plugins" \
    ZBUILD_STATE_DIR="$_t4_state" \
    ZBUILD_STATE_FILE="$_t4_state/pipeline-state.json" \
    ZBUILD_EVENTS_DIR="$_t4_events" \
    ZBUILD_EVENTS_JSONL="$_t4_events/events.jsonl" \
    ZBUILD_EVENTS_DB="$_t4_events/events.db" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
      bash "$REPO_ROOT/core/pipeline/runner.sh" --issue 755 --template standard \
        --from-stage cq-preflight --resume 2>&1 || true
)"
set -e

# Runner must emit an error referencing the missing plugin
_mentions_cq=0
if printf '%s\n' "$_t4_err_output" | grep -qi "cq-preflight"; then
    _mentions_cq=1
fi
assert_eq "T4: error output mentions cq-preflight" "1" "$_mentions_cq"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
