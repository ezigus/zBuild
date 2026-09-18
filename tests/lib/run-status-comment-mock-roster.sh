#!/usr/bin/env bash
# tests/lib/run-status-comment-mock-roster.sh — the mock plugin roster
# for a `simple` run, sourced by run-status-comment-runner-test.sh. Not a test
# (no -test.sh suffix, so the tier discovery skips it). Lifted from
# cycle-rate-limit-aborts-run-test.sh with a passing build, a passing test and
# an intake that can be told to sleep (the linear stage the TERM case hits).
# Expects PLUGINS_ROOT to be set by the caller.

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
# #1074: hydrate is the FIRST stage in simple.yaml. This test enumerates the
# roster, and the runner's resolvability preflight refuses to start when any
# leaf has no plugin — so without this stub the pipeline aborts before intake
# and every assertion below fails for a reason unrelated to what it tests.

# build: the router hit the account's rate limit. The stage says so in its v2
# result the way build/lib/summary.sh does after #2111 — disposition
# unavailable, the reset text under data.rate_limit — and returns 1.
_make_build_plugin() {
    local dir="$PLUGINS_ROOT/agent/build"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'MANIFEST'
id: build
name: Test build (passing)
kind: agent
version: 0.0.1
hooks:
  run: build_run
requires:
  core:
    - redaction
provides:
  role: builder
  result_contract: 2
outputs:
  - id: build_summary
    path: ${artifact_dir}/build-summary.json
    type: json
    required: true
    primary: true
MANIFEST
    cat > "$dir/plugin.sh" <<'PLUG'
build_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '%s\n' '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"","data":{}}' \
        > "$state_dir/artifacts/build-summary.json"
    return 0
}
PLUG
}
_make_test_plugin() {
    local dir="$PLUGINS_ROOT/agent/test"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'MANIFEST'
id: test
name: Test test (passing)
kind: agent
version: 0.0.1
hooks:
  run: test_run
requires:
  core:
    - redaction
provides:
  role: tester
MANIFEST
    cat > "$dir/plugin.sh" <<'PLUG'
test_run() { return 0; }
PLUG
}

_make_slow_intake_plugin() {
    local dir="$PLUGINS_ROOT/agent/intake"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'MANIFEST'
id: intake
name: Test intake (optionally slow)
kind: agent
version: 0.0.1
hooks:
  run: intake_run
requires:
  core:
    - redaction
provides:
  role: intake
MANIFEST
    cat > "$dir/plugin.sh" <<'PLUG'
intake_run() {
    if [[ -n "${ZBUILD_TEST_SLOW_MARK:-}" ]]; then
        printf 'running\n' > "$ZBUILD_TEST_SLOW_MARK"
        sleep 20
    fi
    return 0
}
PLUG
}
_make_plugin "hydrate"         "hydrate"
_make_slow_intake_plugin
_make_plan_plugin
_make_design_plugin
_make_design_gate_plugin
_make_plugin "impact"          "impact_analyzer"
_make_build_plugin
_make_test_plugin
_make_plugin "shape-floor"     "shape_floor"
_make_acceptance_gate_plugin
_make_plugin "secret-scan"     "secret_scan"
_make_gate_aggregator_plugin
_make_plugin "review-lens"      "review_lens"
_make_plugin "review-aggregator" "review_aggregator"
_make_plugin "pr"              "pr"

