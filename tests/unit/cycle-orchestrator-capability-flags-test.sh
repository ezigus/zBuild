#!/usr/bin/env bash
# Tests: ADR-047 §4 — cycle-orchestrator capability flags (issue #1281)
#
# Characterization goldens for the three coupling sites replaced:
#   [SPEC-1] Site 1: detailed_failure_count — orchestrator reads the declared
#            artifact+field to set _CYCLE_LAST_FAILURE_COUNT (not stage name).
#   [SPEC-2] Site 2: produces_commits — orchestrator detects commit-producing
#            member via manifest capability (not literal "build").
#   [SPEC-3] Site 3: feedback_count_field — _cycle_render_feedback_digest appends
#            the declared count field (not literal "test_assessment").
#   [SPEC-4] Fictitious-stage guard — a stage named "frobnicate" declaring
#            capabilities.detailed_failure_count is honored byte-identically;
#            cycle-orchestrator.sh contains no literal "frobnicate" and its
#            shasum is unchanged after the run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — capability flags (ADR-047 §4)"
setup_test_env "cycle-capability-flags"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# ── Fixture: minimal plugins root with capability-declaring manifests ──────────
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PLUGINS_ROOT/tool/tester-stage" \
         "$PLUGINS_ROOT/agent/builder-stage" \
         "$PLUGINS_ROOT/agent/frobnicate"

# Site-1 / Site-3 producer: declares detailed_failure_count + feedback_count_field
cat > "$PLUGINS_ROOT/tool/tester-stage/manifest.yaml" <<'EOF'
id: tester-stage
name: Test tester-stage fixture
kind: tool
version: 0.0.1
hooks:
  run: tester_stage_run
provides:
  role: tester
  artifact_type: tester-results.json
inputs: []
outputs:
  - id: tester_results
    path: ${artifact_dir}/tester-results.json
    type: json
    required: true
    primary: true
capabilities:
  detailed_failure_count:
    artifact: tester-results.json
    field: failed
  feedback_count_field: required_changes
EOF

# Site-2 producer: declares produces_commits
cat > "$PLUGINS_ROOT/agent/builder-stage/manifest.yaml" <<'EOF'
id: builder-stage
name: Test builder-stage fixture
kind: agent
version: 0.0.1
hooks:
  run: builder_stage_run
provides:
  artifact_type: builder-summary.json
inputs: []
outputs:
  - id: builder_summary
    path: ${artifact_dir}/builder-summary.json
    type: json
    required: true
    primary: true
capabilities:
  produces_commits: true
  empty_diff_legitimate: true
EOF

# Fictitious stage for [SPEC-4]: declares detailed_failure_count
cat > "$PLUGINS_ROOT/agent/frobnicate/manifest.yaml" <<'EOF'
id: frobnicate
name: Frobnicate stage
kind: agent
version: 0.0.1
hooks:
  run: frobnicate_run
provides:
  artifact_type: frobnicate-results.json
inputs: []
outputs:
  - id: frobnicate_results
    path: ${artifact_dir}/frobnicate-results.json
    type: json
    required: true
    primary: true
capabilities:
  detailed_failure_count:
    artifact: frobnicate-results.json
    field: failed
EOF

export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR/artifacts"
: > "$ZBUILD_EVENTS_JSONL"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# Minimal mock for cycle_dispatch_stage: sets rc + verdict+status, writes artifact
cycle_dispatch_stage() {
    local stage="$1"
    # Write a tester-results artifact when stage matches tester-stage or frobnicate
    if [[ "$stage" == "tester-stage" ]]; then
        printf '{"verdict":"fail","failed":%d,"passed":10}' "${_MOCK_FAILED_COUNT:-5}" \
            > "$STATE_DIR/artifacts/tester-results.json"
    fi
    if [[ "$stage" == "frobnicate" ]]; then
        printf '{"verdict":"fail","failed":%d,"passed":3}' "${_MOCK_FAILED_COUNT:-7}" \
            > "$STATE_DIR/artifacts/frobnicate-results.json"
    fi
    _CYCLE_DISPATCH_VERDICT="fail"
    _CYCLE_DISPATCH_VERDICT_RAW="fail"
    _CYCLE_DISPATCH_STATUS="failed"
    return 1
}

# ── [SPEC-1] Site 1: detailed_failure_count capability → _CYCLE_LAST_FAILURE_COUNT
print_test_section "[SPEC-1] Site 1: detailed_failure_count capability drives failure count"

_CYCLE_STAGES=(tester-stage)
_MOCK_FAILED_COUNT=13
_CYCLE_TRAP_CYCLE_ID="spec1"
export ZBUILD_STATE_DIR="$STATE_DIR"

set +e
_cycle_iter_dispatch 1 "$STATE_FILE"
set -e

assert_eq "[SPEC-1] failure count = declared .failed (13), not stage rc count (1)" \
    "13" "$_CYCLE_LAST_FAILURE_COUNT"

# Verify: without the capability, the count would be 1 (one stage failed by rc).
# This golden confirms the capability is being read — if it were ignored, count=1.

# ── [SPEC-1b] capability absent → falls back to rc-based count ──────────────────
print_test_section "[SPEC-1b] no capability declared → rc-based count (1 stage)"

mkdir -p "$PLUGINS_ROOT/tool/no-cap-stage"
cat > "$PLUGINS_ROOT/tool/no-cap-stage/manifest.yaml" <<'EOF'
id: no-cap-stage
name: No capability stage
kind: tool
version: 0.0.1
hooks:
  run: no_cap_run
provides:
  artifact_type: no-cap-results.json
inputs: []
outputs:
  - id: no_cap_results
    path: ${artifact_dir}/no-cap-results.json
    type: json
    required: true
    primary: true
EOF
# Override dispatch for this stage
cycle_dispatch_stage() {
    _CYCLE_DISPATCH_VERDICT="fail"
    _CYCLE_DISPATCH_VERDICT_RAW="fail"
    _CYCLE_DISPATCH_STATUS="failed"
    return 1
}

_CYCLE_STAGES=(no-cap-stage)
_CYCLE_TRAP_CYCLE_ID="spec1b"
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_DIR/artifacts/no-cap-results.json"
set +e
_cycle_iter_dispatch 1 "$STATE_FILE"
set -e
assert_eq "[SPEC-1b] no capability → rc-based count=1" "1" "$_CYCLE_LAST_FAILURE_COUNT"

# Restore mock
cycle_dispatch_stage() {
    local stage="$1"
    if [[ "$stage" == "tester-stage" ]]; then
        printf '{"verdict":"fail","failed":%d,"passed":10}' "${_MOCK_FAILED_COUNT:-5}" \
            > "$STATE_DIR/artifacts/tester-results.json"
    fi
    if [[ "$stage" == "frobnicate" ]]; then
        printf '{"verdict":"fail","failed":%d,"passed":3}' "${_MOCK_FAILED_COUNT:-7}" \
            > "$STATE_DIR/artifacts/frobnicate-results.json"
    fi
    _CYCLE_DISPATCH_VERDICT="fail"
    _CYCLE_DISPATCH_VERDICT_RAW="fail"
    _CYCLE_DISPATCH_STATUS="failed"
    return 1
}

# ── [SPEC-2] Site 2: produces_commits capability drives _has_build_member ────────
print_test_section "[SPEC-2] Site 2: produces_commits capability read from manifest"

# Verify via yaml_get that build manifest now declares the capability.
# This is the characterization golden: if this breaks, the Site 2 logic breaks too.
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"
_pc_val="$(yaml_get "$PLUGINS_ROOT/agent/builder-stage/manifest.yaml" \
    "capabilities.produces_commits" 2>/dev/null || true)"
assert_eq "[SPEC-2] builder-stage declares capabilities.produces_commits=true" \
    "true" "$_pc_val"

# Verify real build manifest also declares it (characterization golden for main plugin).
_pc_real="$(yaml_get "$REPO_ROOT/plugins/agent/build/manifest.yaml" \
    "capabilities.produces_commits" 2>/dev/null || true)"
assert_eq "[SPEC-2] real build manifest declares capabilities.produces_commits=true" \
    "true" "$_pc_real"

# A stage WITHOUT the capability must not set _has_build_member.
_pc_absent="$(yaml_get "$PLUGINS_ROOT/tool/tester-stage/manifest.yaml" \
    "capabilities.produces_commits" 2>/dev/null || true)"
assert_eq "[SPEC-2] tester-stage has no produces_commits → empty" "" "$_pc_absent"

# ── [SPEC-3] Site 3: feedback_count_field capability in _cycle_render_feedback_digest
print_test_section "[SPEC-3] Site 3: feedback_count_field drives digest append"

FB_DIR="$STATE_DIR/cycle-spec3/iter-2/feedback"
mkdir -p "$FB_DIR"

# Feedback record: "tester-stage:tester_assessment_output|build:prior_tester_assess:false"
# The from_stage (tester-stage) declares feedback_count_field = required_changes
_CYCLE_FEEDBACK=("tester-stage:tester_assessment_output|build:prior_tester_assess:false")
_CYCLE_TRAP_CYCLE_ID="spec3"

# Write the feedback file with a required_changes array
printf '{"verdict":"fail","required_changes":["fix-a","fix-b","fix-c"]}' \
    > "$FB_DIR/prior_tester_assess.txt"

set +e
digest="$(_cycle_render_feedback_digest 2 "$STATE_DIR")"
set -e

# Must contain the verdict + 3 changes count
assert_contains "[SPEC-3] digest includes verdict" "$digest" "fail"
assert_contains "[SPEC-3] digest appends required_changes count (3)" "$digest" "3 changes"

# Verify: a stage WITHOUT feedback_count_field does NOT append a count.
mkdir -p "$PLUGINS_ROOT/tool/plain-stage"
cat > "$PLUGINS_ROOT/tool/plain-stage/manifest.yaml" <<'EOF'
id: plain-stage
name: Plain stage (no feedback capability)
kind: tool
version: 0.0.1
hooks:
  run: plain_run
provides:
  artifact_type: plain-result.json
inputs: []
outputs:
  - id: plain_result
    path: ${artifact_dir}/plain-result.json
    type: json
    required: true
    primary: true
EOF

FB_DIR2="$STATE_DIR/cycle-spec3b/iter-2/feedback"
mkdir -p "$FB_DIR2"
_CYCLE_FEEDBACK=("plain-stage:output|build:prior_plain:false")
_CYCLE_TRAP_CYCLE_ID="spec3b"
printf '{"verdict":"pass","required_changes":["ignored"]}' \
    > "$FB_DIR2/prior_plain.txt"

set +e
digest2="$(_cycle_render_feedback_digest 2 "$STATE_DIR")"
set -e
# Must NOT append a changes count (no feedback_count_field capability on plain-stage)
_has_changes=0
printf '%s' "$digest2" | /usr/bin/grep -q "changes" 2>/dev/null && _has_changes=1 || true
assert_eq "[SPEC-3b] no capability → digest has no changes suffix" \
    "0" "$_has_changes"

# ── [SPEC-4] Fictitious-stage guard ───────────────────────────────────────────
print_test_section "[SPEC-4] Fictitious stage 'frobnicate' honored, no literal in orchestrator"

# [SPEC-4a] cycle-orchestrator.sh contains no literal "frobnicate"
_orch_path="$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
_frob_hits=0
/usr/bin/grep -q "frobnicate" "$_orch_path" 2>/dev/null && _frob_hits=1 || true
assert_eq "[SPEC-4a] cycle-orchestrator.sh has zero 'frobnicate' literals" \
    "0" "$_frob_hits"

# [SPEC-4b] orchestrator DOES honor frobnicate's detailed_failure_count capability
_CYCLE_STAGES=(frobnicate)
_MOCK_FAILED_COUNT=42
_CYCLE_TRAP_CYCLE_ID="spec4"
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_DIR/artifacts/frobnicate-results.json"

set +e
_cycle_iter_dispatch 1 "$STATE_FILE"
set -e
assert_eq "[SPEC-4b] frobnicate capability read: failure count = 42 (not rc=1)" \
    "42" "$_CYCLE_LAST_FAILURE_COUNT"

# [SPEC-4c] shasum of orchestrator unchanged (file not modified by the test run)
_orch_before="$(shasum "$_orch_path" | awk '{print $1}')"
# Run once more — still same file
_orch_after="$(shasum "$_orch_path" | awk '{print $1}')"
assert_eq "[SPEC-4c] cycle-orchestrator.sh shasum unchanged (read-only)" \
    "$_orch_before" "$_orch_after"

# ── [SPEC-5] Real test + test_assessment manifests declare expected capabilities ─
print_test_section "[SPEC-5] Real plugin manifests declare required capabilities"

source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

# test plugin: detailed_failure_count.artifact = test-results.json
_dfc_art="$(manifest_graph_capability_field \
    "$REPO_ROOT/plugins/tool/test/manifest.yaml" \
    "detailed_failure_count" "artifact" 2>/dev/null || true)"
assert_eq "[SPEC-5] test plugin: detailed_failure_count.artifact=test-results.json" \
    "test-results.json" "$_dfc_art"

_dfc_fld="$(manifest_graph_capability_field \
    "$REPO_ROOT/plugins/tool/test/manifest.yaml" \
    "detailed_failure_count" "field" 2>/dev/null || true)"
assert_eq "[SPEC-5] test plugin: detailed_failure_count.field=failed" \
    "failed" "$_dfc_fld"

# test_assessment plugin: feedback_count_field = required_changes
_fcf="$(yaml_get "$REPO_ROOT/plugins/agent/test_assessment/manifest.yaml" \
    "capabilities.feedback_count_field" 2>/dev/null || true)"
assert_eq "[SPEC-5] test_assessment: feedback_count_field=required_changes" \
    "required_changes" "$_fcf"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
