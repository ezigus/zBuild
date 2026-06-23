#!/usr/bin/env bash
# Integration: ADR-021 v2 (#527/#528) + #766 — when a cycle exhausts
# max_iterations with on_max=continue, the runner MUST emit cycle.unconverged
# and proceed to the next dispatch unit. pipeline.abort (EXIT trap) must NOT
# fire — only pipeline.end status=failed is the correct terminal event.
#
# Dogfood evidence: run_id 20260608223447-42915 showed pipeline.abort firing
# directly after cycle.complete reason=max_iterations, with no cycle.unconverged
# event between them. The architect analysis confirmed runner.sh:1278-1298 IS
# the documented continue path; the bug is a `set -e` trip somewhere between
# the cycle return and that line. This test reproduces that bug end-to-end
# through the runner (not just the orchestrator).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cycle on_max=continue → runner continues to next cycle (#766)"
setup_test_env "cycle-on-max-pipeline-continues"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=1
export ZBUILD_CONTRACT_VALIDATOR=warn
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# ─── Stub plugins (every required role) ──────────────────────────────────
# intake/plan/build/test/test_assessment/review succeed.
# impact ALWAYS emits verdict=incomplete so design_impact_cycle exhausts.
_make_plugin() {
    local id="$1" role="${2:-}" rc="${3:-0}"
    local dir="$PLUGINS_ROOT/agent/$id"
    mkdir -p "$dir"
    local fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: agent
version: 0.0.1
hooks:
  run: $fn
requires:
  core:
    - redaction
${role:+provides:
  role: $role}
EOF
    cat > "$dir/plugin.sh" <<PLUG
${fn}() { return $rc; }
PLUG
}

# Override design to produce design.md with a scope block (so impact's input contract holds)
_make_design_plugin() {
    local dir="$PLUGINS_ROOT/agent/design"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: design
name: Test design
kind: agent
version: 0.0.1
hooks:
  run: design_run
requires:
  core:
    - redaction
provides:
  role: designer
outputs:
  - id: design_out
    path: ${artifact_dir}/design.md
    type: text/markdown
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
design_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '# Design\n```scope\nf.txt\n```\n' > "$state_dir/artifacts/design.md"
    return 0
}
PLUG
}

# Override impact to emit verdict=incomplete via primary artifact
# (so design_impact_cycle exit_when never matches, exhausting max_iterations).
_make_impact_plugin() {
    local dir="$PLUGINS_ROOT/agent/impact"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: impact
name: Test impact
kind: agent
version: 0.0.1
hooks:
  run: impact_run
requires:
  core:
    - redaction
provides:
  role: impact_analyzer
outputs:
  - id: impact_out
    path: ${artifact_dir}/impact.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
impact_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"incomplete","missing":[],"impact_feedback_md":"forced incomplete to test max_iterations"}' \
        > "$state_dir/artifacts/impact.json"
    return 0
}
PLUG
}

# Override plan so it always produces a valid plan.json (plan is now a leaf — no cycle feedback).
_make_plan_plugin() {
    local dir="$PLUGINS_ROOT/agent/plan"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: plan
name: Test plan
kind: agent
version: 0.0.1
hooks:
  run: plan_run
requires:
  core:
    - redaction
provides:
  role: planner
outputs:
  - id: plan_out
    path: ${artifact_dir}/plan.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
plan_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["f.txt"],"estimated_lines":1}],"estimated_total_lines":1,"notes":""}' \
        > "$state_dir/artifacts/plan.json"
    return 0
}
PLUG
}

# Stubs for every role the standard template needs.
_make_plugin "intake"          "intake"
_make_plan_plugin
_make_design_plugin
_make_impact_plugin
_make_plugin "build"           "builder"
_make_plugin "test"            "tester"
_make_plugin "test_assessment" "test_assessment"
# #922: acceptance-gate leaf stage (ADR-036).
_make_plugin "acceptance-gate" "acceptance_gate"
# #755: build_review_cycle.flow now includes the 4 compound_quality stages.
_make_plugin "cq-preflight"    "cq_preflight"
_make_plugin "cq-audit-plan"   "cq_audit_plan"
_make_plugin "cq-cycle"        "cq_cycle"
_make_plugin "cq-backtrack"    "cq_backtrack"
_make_plugin "review"          "reviewer"
# #756: pr leaf stage after build_review_cycle uses the pr_delivery role.
_make_plugin "pr"              "pr_delivery"

# Force test_assessment to emit verdict=pass so build_test_cycle converges fast.
cat > "$PLUGINS_ROOT/agent/test_assessment/plugin.sh" <<'PLUG'
test_assessment_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"pass","summary":"ok","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"","failure_summary_md":"","iter":1}' \
        > "$state_dir/artifacts/test_assessment.json"
    return 0
}
PLUG
# Force review to emit verdict=approve.
cat > "$PLUGINS_ROOT/agent/review/plugin.sh" <<'PLUG'
review_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"approve","summary":"ok","issues":[],"confidence":0.99,"review_md":"ok"}' \
        > "$state_dir/artifacts/review.json"
    return 0
}
PLUG

# ─── Drive runner.sh end-to-end with --template standard ──────────────────
: > "$EVENTS_JSONL"

# Operator override token so intake's scope-precondition passes.
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# We bypass intake by skipping the issue fetch — drive with --goal so it
# doesn't try to gh-CLI an issue.
RUNNER_STDERR="$TEST_TEMP_DIR/runner.stderr"
set +e
bash "$REPO_ROOT/core/pipeline/runner.sh" \
    --goal "test on_max=continue" \
    --template standard \
    --no-resume \
    >"$TEST_TEMP_DIR/runner.stdout" \
    2>"$RUNNER_STDERR"
runner_rc=$?
set -e

print_test_section "T1: events.jsonl chain around design_impact_cycle exhaustion"

# T1.1: cycle.complete fired with a non-convergence terminal reason for
# design_impact_cycle. Accept any of {max_iterations, plateau, divergence} —
# the test's intent (per #766) is to verify the runner continues past
# cycle exit, NOT to pin a specific reason.
mi_count="$(jq -c 'select(.type=="cycle.complete" and (.data.reason=="max_iterations" or .data.reason=="plateau" or .data.reason=="divergence") and .data.cycle_id=="design_impact_cycle")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$mi_count" -ge 1 ]] \
    && assert_pass "T1.1: cycle.complete fired with non-convergence reason for design_impact_cycle (count=$mi_count)" \
    || assert_fail "T1.1: cycle.complete MUST fire with non-convergence reason" "count=$mi_count"

# T1.2: cycle.unconverged event MUST be emitted (proves runner.sh:1292 reached)
unconv_count="$(jq -c 'select(.type=="cycle.unconverged" and .data.cycle_id=="design_impact_cycle")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T1.2: cycle.unconverged event emitted (proves runner continues past cycle exit)" "1" "$unconv_count"

# T1.3: pipeline.abort (EXIT trap) MUST NOT fire on the on_max=continue path
abort_count="$(jq -c 'select(.type=="pipeline.abort")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T1.3: pipeline.abort MUST NOT fire on on_max=continue cycle exhaustion" "0" "$abort_count"

# T1.4: pipeline.end emitted exactly once
end_count="$(jq -c 'select(.type=="pipeline.end")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T1.4: pipeline.end emitted exactly once" "1" "$end_count"

# T1.5 (amended #796 / ADR-021 v3 R1): when on_max=continue AND downstream review
# verdict=approve, pipeline.end status=success (NOT failed). The cycle.unconverged
# event still fires for forensics, but pipeline status reflects the FINAL stage
# outcome — review approved, so pipeline succeeded with a warning.
# Previously (#527, pre-#796) this was "failed" — that contradicted on_max=continue
# semantics and produced false-failure operator banners on substantively
# successful runs (dogfood run_id 20260611072619-15296).
end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T1.5: pipeline.end status=success (on_max=continue + review approved, #796)" "success" "$end_status"

print_test_section "T2: build_review_cycle dispatched after design_impact_cycle exhausted"

# T2.1: build_review_cycle entered (build runs at least once because build_review_cycle's inner build_test_cycle runs)
build_run_count="$(jq -c 'select(.type=="plugin.run.start" and .data.plugin=="build")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$build_run_count" -ge 1 ]] \
    && assert_pass "T2.1: build plugin ran (proves build_review_cycle was dispatched after design_impact_cycle exhausted)" \
    || assert_fail "T2.1: build plugin did NOT run (runner stopped before build_review_cycle)" "build_run_count=$build_run_count"

# T2.2: review stage ran (proves build_review_cycle's review member dispatched)
review_run_count="$(jq -c 'select(.type=="plugin.run.start" and .data.plugin=="review")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$review_run_count" -ge 1 ]] \
    && assert_pass "T2.2: review plugin ran (proves build_review_cycle reached its review member)" \
    || assert_fail "T2.2: review plugin did NOT run" "review_run_count=$review_run_count"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
