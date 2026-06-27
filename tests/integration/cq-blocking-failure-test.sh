#!/usr/bin/env bash
# Integration: CQ-3 / ADR-013 (#863) — blocking cycle-member enforcement.
# When a blocking CQ stage (cq-preflight, cq-audit-plan, cq-cycle) fails,
# cycle_orchestrator_run returns rc=8, runner.sh halts with pipeline.end
# status=failed, and no subsequent cycle members execute.
# Non-blocking member (cq-backtrack) failure still allows the cycle to continue
# to review and succeed when review approves.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "CQ-3: blocking cycle-member failure halts pipeline (#863)"
setup_test_env "cq-blocking-failure"

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

# ─── Plugin stub helpers ──────────────────────────────────────────────────────

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
    printf '{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"ok"}' \
        > "$state_dir/artifacts/impact.json"
    return 0
}
PLUG
}

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

# ─── Build common plugin stubs (rc=0 unless overridden below) ─────────────────
_make_plugin "intake"          "intake"
_make_plan_plugin
_make_design_plugin
_make_impact_plugin
_make_plugin "build"           "builder"
_make_plugin "test"            "tester"
_make_plugin "test_assessment" "test_assessment"
_make_plugin "acceptance-gate" "acceptance_gate"
_make_plugin "cq-preflight"    "cq_preflight"
_make_plugin "cq-audit-plan"   "cq_audit_plan"
_make_plugin "cq-cycle"        "cq_cycle"
_make_plugin "cq-backtrack"    "cq_backtrack"
_make_plugin "review"          "reviewer"
# #756: pr leaf stage after build_review_cycle uses the pr_delivery role.
_make_plugin "pr"              "pr_delivery"

# test_assessment: always emit verdict=pass so build_test_cycle converges.
cat > "$PLUGINS_ROOT/agent/test_assessment/plugin.sh" <<'PLUG'
test_assessment_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"pass","summary":"ok","diagnosis":"","required_changes":[],"agrees_with_build_complete":true,"branch_numstat":"","failure_summary_md":"","iter":1}' \
        > "$state_dir/artifacts/test_assessment.json"
    return 0
}
PLUG

# review: always emit verdict=approve.
cat > "$PLUGINS_ROOT/agent/review/plugin.sh" <<'PLUG'
review_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"approve","summary":"ok","issues":[],"confidence":0.99,"review_md":"ok"}' \
        > "$state_dir/artifacts/review.json"
    return 0
}
PLUG

# ─── Operator override token ──────────────────────────────────────────────────
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ─── Helper: run the pipeline, capture events ─────────────────────────────────
_run_pipeline() {
    : > "$EVENTS_JSONL"
    local stderr_file="$TEST_TEMP_DIR/runner.stderr"
    set +e
    bash "$REPO_ROOT/core/pipeline/runner.sh" \
        --goal "test cq-blocking" \
        --template standard \
        --no-resume \
        >"$TEST_TEMP_DIR/runner.stdout" \
        2>"$stderr_file"
    set -e
}

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-1] cq-preflight exits 1 → pipeline.end status=failed
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T1 [SPEC-1]: cq-preflight fails → pipeline.end status=failed"

# Override cq-preflight to fail.
cat > "$PLUGINS_ROOT/agent/cq-preflight/plugin.sh" <<'PLUG'
cq_preflight_run() { return 1; }
PLUG

_run_pipeline

end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
# [SPEC-1]
assert_eq "T1 [SPEC-1]: pipeline.end status=failed when cq-preflight fails" "failed" "$end_status"

# [SPEC-4] state file .status must equal "failed" (not "interrupted") for rc=8.
state_status="$(jq -r '.status' "$STATE_DIR/pipeline-state.json" 2>/dev/null)"
assert_eq "T1 [SPEC-4]: state file status=failed when cq-preflight blocks" "failed" "$state_status"

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-2] After cq-preflight fails, cq-audit-plan, cq-cycle, cq-backtrack
#          must NOT run (plugin.run.start count = 0 for each)
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T2 [SPEC-2]: blocking halt skips subsequent cycle members"

for stage in "cq-audit-plan" "cq-cycle" "cq-backtrack" "review"; do
    count="$(jq -c --arg p "$stage" \
        'select(.type=="plugin.run.start" and .data.plugin==$p)' \
        "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
    # [SPEC-2]
    assert_eq "T2 [SPEC-2]: $stage did NOT run after cq-preflight failure" "0" "$count"
done

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-3] cq-backtrack exits 1 (non-blocking), review approves → status=success
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T3 [SPEC-3]: cq-backtrack (non-blocking) failure → pipeline succeeds"

# Restore cq-preflight to pass; make cq-backtrack fail.
cat > "$PLUGINS_ROOT/agent/cq-preflight/plugin.sh" <<'PLUG'
cq_preflight_run() { return 0; }
PLUG
cat > "$PLUGINS_ROOT/agent/cq-backtrack/plugin.sh" <<'PLUG'
cq_backtrack_run() { return 1; }
PLUG

_run_pipeline

end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
# [SPEC-3]
assert_eq "T3 [SPEC-3]: pipeline.end status=success when only non-blocking cq-backtrack fails" "success" "$end_status"

# review must have run (proves non-blocking failure didn't halt the cycle)
review_count="$(jq -c 'select(.type=="plugin.run.start" and .data.plugin=="review")' \
    "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$review_count" -ge 1 ]] \
    && assert_pass "T3 [SPEC-3]: review ran after non-blocking cq-backtrack failure" \
    || assert_fail "T3 [SPEC-3]: review should run after non-blocking failure" "review_count=$review_count"
# [SPEC-6] design SPEC: cq-backtrack fails (non-blocking) → review IS dispatched.
# (cq-backtrack was non-blocking before #863 too, so this is a regression guard,
# not a fail-at-baseline change — see #913 change-vs-guard SPEC follow-up.)
[[ "$review_count" -ge 1 ]] \
    && assert_pass "T3 [SPEC-6]: cq-backtrack non-blocking failure → review IS dispatched" \
    || assert_fail "T3 [SPEC-6]: review must be dispatched after a non-blocking failure" "review_count=$review_count"

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-4] All CQ stages pass, review approves → pipeline.end status=success
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T4 [SPEC-4]: all CQ stages pass → pipeline.end status=success"

# Restore cq-backtrack to pass.
cat > "$PLUGINS_ROOT/agent/cq-backtrack/plugin.sh" <<'PLUG'
cq_backtrack_run() { return 0; }
PLUG

_run_pipeline

end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
# [SPEC-4]
assert_eq "T4 [SPEC-4]: pipeline.end status=success when all CQ stages pass" "success" "$end_status"

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-5] cq-audit-plan fails (blocking, cq-preflight passing) → cq-cycle NOT
#   dispatched AND pipeline.end status=failed. Proves blocking enforcement is not
#   cq-preflight-specific: ANY blocking member halts the loop + fail-fasts. Fails
#   at baseline (pre-#863 the cycle swallowed the rc and ran to status=success).
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T6 [SPEC-5]: cq-audit-plan (blocking) failure → halt + status=failed"

# cq-preflight passes (restored at T3); make cq-audit-plan fail.
cat > "$PLUGINS_ROOT/agent/cq-audit-plan/plugin.sh" <<'PLUG'
cq_audit_plan_run() { return 1; }
PLUG

_run_pipeline

end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
# [SPEC-5]
assert_eq "T6 [SPEC-5]: pipeline.end status=failed when blocking cq-audit-plan fails" "failed" "$end_status"

# [SPEC-4] state file .status must also equal "failed" for blocking cq-audit-plan.
state_status_t6="$(jq -r '.status' "$STATE_DIR/pipeline-state.json" 2>/dev/null)"
assert_eq "T6 [SPEC-4]: state file status=failed when cq-audit-plan blocks" "failed" "$state_status_t6"

# cq-cycle must NOT have run (fail-fast skips the rest after a blocking failure).
cqcycle_count="$(jq -c 'select(.type=="plugin.run.start" and .data.plugin=="cq-cycle")' \
    "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
# [SPEC-5]
assert_eq "T6 [SPEC-5]: cq-cycle did NOT run after cq-audit-plan blocking failure" "0" "$cqcycle_count"

# Restore cq-audit-plan to pass so subsequent sections are unaffected.
cat > "$PLUGINS_ROOT/agent/cq-audit-plan/plugin.sh" <<'PLUG'
cq_audit_plan_run() { return 0; }
PLUG

# ─────────────────────────────────────────────────────────────────────────────
# T5: on_max=continue — design_impact_cycle exhausts max_iterations (verdict=
# incomplete), build_review_cycle still runs and review approves → status=success.
# Regression: blocking enforcement must not break the on_max=continue soft-fail path.
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T5: on_max=continue convergence soft-fail unaffected by blocking enforcement"

# Force impact to always return incomplete so design_impact_cycle exhausts max_iterations.
cat > "$PLUGINS_ROOT/agent/impact/plugin.sh" <<'PLUG'
impact_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"incomplete","missing":[],"impact_feedback_md":"forced incomplete"}' \
        > "$state_dir/artifacts/impact.json"
    return 0
}
PLUG
# Restore review to return approve (so build_review_cycle converges once it runs).
cat > "$PLUGINS_ROOT/agent/review/plugin.sh" <<'PLUG'
review_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"approve","summary":"ok","issues":[],"confidence":0.99,"review_md":"ok"}' \
        > "$state_dir/artifacts/review.json"
    return 0
}
PLUG

_run_pipeline

end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T5: on_max=continue + downstream review approved → pipeline.end status=success" "success" "$end_status"

# Verify cycle.unconverged fired (proves the on_max=continue path was exercised).
unconv="$(jq -c 'select(.type=="cycle.unconverged" and .data.cycle_id=="design_impact_cycle")' \
    "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$unconv" -ge 1 ]] \
    && assert_pass "T5: cycle.unconverged emitted for design_impact_cycle (on_max=continue path confirmed)" \
    || assert_fail "T5: cycle.unconverged not emitted — on_max=continue path not exercised" "unconv=$unconv"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
