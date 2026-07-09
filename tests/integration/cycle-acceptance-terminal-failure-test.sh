#!/usr/bin/env bash
# Integration: #1044 / #1188 — acceptance-gate verdict=fail behavior at cycle end.
# When the acceptance-gate writes verdict=fail with a TERMINAL (genuine-violation)
# class (inert_wiring / tautology / not_passing_at_head), the build_test_cycle
# must NOT converge — the pipeline halts with pipeline.end status=failed (rc=8
# propagated outward).
# Complementary NON-terminal classes let the cycle converge → status=success:
# untagged_spec (RECOVERABLE, #951 feedback) and the ADR-036 #1188 INFRA classes
# negctl_error:* / reachability_error:* (resolve/worktree/timeout).
# This locks SPEC-2 and the #1188 infra-non-terminal contract end-to-end.
# (#979: re-pointed from the retired standard.yaml to the shipped default
# simple.yaml — the acceptance-gate is a build_test_cycle member in both; the
# disposition→terminal/non-terminal mechanic is engine code, template-agnostic.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "#1044: acceptance terminal failure halts pipeline"
setup_test_env "cycle-acceptance-terminal-failure"

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

# acceptance-gate stub: writes the gate_result with a configurable failure entry
# (via ZBUILD_TEST_GATE_FAILURE) and returns rc=1 (the real gate does this for
# EVERY fail class). An empty failure → verdict=pass, rc=0.
_make_acceptance_gate_plugin() {
    local dir="$PLUGINS_ROOT/agent/acceptance-gate"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: acceptance-gate
name: Test acceptance-gate
kind: agent
version: 0.0.1
hooks:
  run: acceptance_gate_run
requires:
  core:
    - redaction
provides:
  role: acceptance_gate
outputs:
  - id: gate_result
    path: ${artifact_dir}/acceptance-gate-result.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
acceptance_gate_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    local f="${ZBUILD_TEST_GATE_FAILURE:-}"
    if [[ -z "$f" ]]; then
        printf '{"verdict":"pass","disposition":"none","failures":[]}' \
            > "$state_dir/artifacts/acceptance-gate-result.json"
        return 0
    fi
    # Mirror the real gate's class→disposition mapping (ADR-021 / ADR-036): the
    # engine reads ONLY this generic disposition field, not the failure class.
    local disp
    case "$f" in
        untagged_spec:*)                        disp="recoverable" ;;
        negctl_error:* | reachability_error:*)  disp="advisory" ;;
        *)                                      disp="terminal" ;;
    esac
    printf '{"verdict":"fail","disposition":"%s","failures":["%s"]}' "$disp" "$f" \
        > "$state_dir/artifacts/acceptance-gate-result.json"
    return 1
}
PLUG
}

# design-gate stub: always passes so design_verify_cycle converges on iter 1
# (this test's subject is the build_test_cycle acceptance-gate, not design).
_make_design_gate_plugin() {
    local dir="$PLUGINS_ROOT/agent/design-gate"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: design-gate
name: Test design-gate
kind: agent
version: 0.0.1
hooks:
  run: design_gate_run
requires:
  core:
    - redaction
provides:
  role: design_gate
outputs:
  - id: design_gate_out
    path: ${artifact_dir}/design-gate.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
design_gate_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"pass","summary":"ok"}' \
        > "$state_dir/artifacts/design-gate.json"
    return 0
}
PLUG
}

# gate-aggregator stub: rolls the acceptance-gate result into the cycle's
# convergence verdict. A TERMINAL acceptance disposition is hard-halted by the
# orchestrator BEFORE the aggregator (rc=8), so this only governs the
# non-terminal cases: for pass / recoverable / advisory it emits verdict=pass so
# build_test_cycle converges (and status=success WITHOUT the retired review
# rescue). This mirrors the real gate-aggregator, which never blocks on an
# advisory/recoverable member.
_make_gate_aggregator_plugin() {
    local dir="$PLUGINS_ROOT/agent/gate-aggregator"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: gate-aggregator
name: Test gate-aggregator
kind: agent
version: 0.0.1
hooks:
  run: gate_aggregator_run
requires:
  core:
    - redaction
provides:
  role: gate_aggregator
outputs:
  - id: gate_aggregator_out
    path: ${artifact_dir}/gate-aggregator.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
gate_aggregator_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"schema_version":1,"verdict":"pass","summary":"ok","gates":[]}' \
        > "$state_dir/artifacts/gate-aggregator.json"
    return 0
}
PLUG
}

# ─── Build common plugin stubs (rc=0 unless overridden below) ─────────────────
# #979: standard.yaml retired → drive the shipped default simple.yaml. The
# acceptance-gate is a member of simple.yaml's build_test_cycle; its
# disposition→terminal/recoverable/advisory mechanic (the subject) is unchanged.
# For a non-terminal disposition the gate-aggregator passes → the cycle converges
# normally → status=success WITHOUT relying on the retired review-stage rescue
# path (see the T2/T3 #979 notes below). A terminal disposition hard-halts (rc=8).
_make_plugin "intake"          "intake"
_make_plan_plugin
_make_design_plugin
_make_design_gate_plugin       # passes so design_verify_cycle converges quickly
_make_plugin "impact"          "impact_analyzer"
_make_plugin "build"           "builder"
_make_plugin "test"            "tester"
_make_plugin "shape-floor"     "shape_floor"
_make_acceptance_gate_plugin
_make_plugin "secret-scan"     "secret_scan"
_make_gate_aggregator_plugin   # verdict mirrors acceptance disposition
# review_lenses is now a map group (#1295): one plugin for role review_lens
# handles all elements (security, performance, red-team, correctness, scope).
_make_plugin "review-lens"      "review_lens"
_make_plugin "review-aggregator" "review_aggregator"
_make_plugin "pr"              "pr"

# ─── Operator override token ──────────────────────────────────────────────────
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ─── Helper: run the pipeline, capture events ─────────────────────────────────
_run_pipeline() {
    : > "$EVENTS_JSONL"
    set +e
    bash "$REPO_ROOT/core/pipeline/runner.sh" \
        --goal "test acceptance-terminal" \
        --template simple \
        --no-resume \
        >"$TEST_TEMP_DIR/runner.stdout" \
        2>"$TEST_TEMP_DIR/runner.stderr"
    set -e
}

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-4] review approves but acceptance-gate writes a TERMINAL failure
#          (inert_wiring) → pipeline.end status=failed, NOT complete/success.
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T1 [SPEC-4]: terminal acceptance failure (inert_wiring) halts cycle (rc=8)"

export ZBUILD_TEST_GATE_FAILURE="inert_wiring:config/x.yaml"
_run_pipeline

end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
# [SPEC-4]
assert_eq "T1 [SPEC-4]: pipeline.end status=failed on terminal acceptance failure" "failed" "$end_status"

# Diagnostic event must fire when a member's disposition=terminal makes the
# verdict load-bearing. GENERIC event carrying the failing member id.
term_evt="$(jq -c 'select(.type=="cycle.member.terminal_failure")' \
    "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$term_evt" -ge 1 ]] \
    && assert_pass "T1 [SPEC-4]: cycle.member.terminal_failure emitted" \
    || assert_fail "T1 [SPEC-4]: cycle.member.terminal_failure should be emitted" "count=$term_evt"

# The event must name the acceptance-gate member (plugin-agnostic engine, but the
# member id is carried in data).
term_member="$(jq -r 'select(.type=="cycle.member.terminal_failure") | .data.member' \
    "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T1 [SPEC-4]: terminal_failure event names the failing member" "acceptance-gate" "$term_member"

# The cycle status written to durable state must NOT be complete.
cyc_complete="$(jq -c 'select(.type=="cycle.complete" and .data.cycle_id=="build_test_cycle" and .data.reason=="converged")' \
    "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T1 [SPEC-4]: build_test_cycle did NOT converge (no reason=converged)" "0" "$cyc_complete"

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-2] untagged_spec-only failure is RECOVERABLE — must NOT hard-abort.
#          The cycle CONVERGES (gate-aggregator passes on a non-terminal member)
#          → pipeline reaches status=success. (#979: no review-rescue needed —
#          convergence means no unconverged cycle, so the terminal status is
#          success by the normal converged path.)
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T2 [SPEC-2]: untagged_spec-only acceptance failure does NOT halt (status=success)"

export ZBUILD_TEST_GATE_FAILURE="untagged_spec:SPEC-1"
_run_pipeline

end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
# [SPEC-2]
assert_eq "T2 [SPEC-2]: pipeline.end status=success on untagged_spec-only (feedback preserved)" "success" "$end_status"

# No terminal-failure event for the recoverable class.
term_evt="$(jq -c 'select(.type=="cycle.member.terminal_failure")' \
    "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T2 [SPEC-2]: cycle.member.terminal_failure NOT emitted for untagged_spec" "0" "$term_evt"

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-5] infra failure (negctl_error:timeout) is NON-terminal (ADR-036 #1188).
#          A flaky/slow sandbox must NOT hard-fail the pipeline — the cycle
#          converges → status=success, and NO terminal-failure event fires.
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T3 [SPEC-5]: infra negctl_error:timeout does NOT halt (status=success)"

export ZBUILD_TEST_GATE_FAILURE="negctl_error:timeout:SPEC-1"
_run_pipeline

end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T3 [SPEC-5]: pipeline.end status=success on negctl_error:timeout (infra non-terminal)" "success" "$end_status"

term_evt="$(jq -c 'select(.type=="cycle.member.terminal_failure")' \
    "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T3 [SPEC-5]: cycle.member.terminal_failure NOT emitted for infra timeout" "0" "$term_evt"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
