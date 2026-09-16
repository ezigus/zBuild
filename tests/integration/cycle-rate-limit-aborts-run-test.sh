#!/usr/bin/env bash
# Integration: #2111 — a rate-limited stage ENDS the run.
# The build stub declares the v2 result the real build writes after #2111
# (disposition:unavailable, reason:router_rate_limited, the reset text under
# data.rate_limit.message) and returns 1. The engine must then halt on
# halt_unavailable: no re-dispatch, no later member (the recording test stub
# never runs), no second iteration; the run ends pipeline.end status=aborted
# with pipeline.aborted reason=llm_rate_limited carrying the reset text, the
# runner exits 9, and pipeline-state.json records status=aborted +
# reason=llm_rate_limited so an ADR-050 resume can pick it up after the reset.
# Real runner (core/pipeline/runner.sh --template simple) over stub plugins.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "#2111: a rate-limited stage ends the run — aborted, not re-verified"
setup_test_env "cycle-rate-limit-aborts"

# #1921 follow-up: the runner resolves repo_root from CWD, so a --goal run
# started from the working checkout snapshots zbuild/state/goal-<hash> into it.
# Measured in an isolated clone: a full suite went from 0 state refs to 2, both
# goal refs, and this file produced one of them. The issue-keyed sweep missed
# these because it looked for issue identity.
_ZB_REPO="$(zb_test_repo cycle-rate-limit)"
_ZB_GOAL="$(zb_test_goal rate-limit-abort)"

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
# #1074: hydrate is the FIRST stage in simple.yaml. This test enumerates the
# roster, and the runner's resolvability preflight refuses to start when any
# leaf has no plugin — so without this stub the pipeline aborts before intake
# and every assertion below fails for a reason unrelated to what it tests.

# build: the router hit the account's rate limit. The stage says so in its v2
# result the way build/lib/summary.sh does after #2111 — disposition
# unavailable, the reset text under data.rate_limit — and returns 1.
_make_rate_limited_build_plugin() {
    local dir="$PLUGINS_ROOT/agent/build"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: build
name: Test build (rate-limited)
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
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
build_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '%s\n' '{"result_contract":2,"verdict":"incomplete","disposition":"unavailable","reason":"router_rate_limited","data":{"rate_limit":{"message":"LLM rate-limited — resets 3pm (UTC)"}}}' \
        > "$state_dir/artifacts/build-summary.json"
    printf 'build ran\n' >> "${ZBUILD_TEST_DISPATCH_LOG:?}"
    return 1
}
PLUG
}
# test: records every dispatch — after a rate-limited build it must never run.
_make_recording_test_plugin() {
    local dir="$PLUGINS_ROOT/agent/test"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: test
name: Test test (recording)
kind: agent
version: 0.0.1
hooks:
  run: test_run
requires:
  core:
    - redaction
provides:
  role: tester
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
test_run() { printf 'test ran\n' >> "${ZBUILD_TEST_DISPATCH_LOG:?}"; return 0; }
PLUG
}

_make_plugin "hydrate"         "hydrate"
_make_plugin "intake"          "intake"
_make_plan_plugin
_make_design_plugin
_make_design_gate_plugin       # passes so design_verify_cycle converges quickly
_make_plugin "impact"          "impact_analyzer"
_make_rate_limited_build_plugin
_make_recording_test_plugin
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
    ( cd "$_ZB_REPO" && bash "$REPO_ROOT/core/pipeline/runner.sh" \
        --goal "$_ZB_GOAL" \
        --template simple \
        --no-resume \
        >"$TEST_TEMP_DIR/runner.stdout" \
        2>"$TEST_TEMP_DIR/runner.stderr" )
    _RUNNER_RC=$?
    set -e
}

# ─────────────────────────────────────────────────────────────────────────────
# The run ends on the rate-limited build: aborted, resumable, nothing after it.
# ─────────────────────────────────────────────────────────────────────────────

export ZBUILD_TEST_DISPATCH_LOG="$TEST_TEMP_DIR/dispatch.log"; : > "$ZBUILD_TEST_DISPATCH_LOG"

print_test_section "[#2111] a rate-limited build ends the run as aborted/llm_rate_limited and dispatches nothing after it"
_run_pipeline
end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "[#2111] pipeline.end status=aborted (not failed, not success)" "aborted" "$end_status"
abort_reason="$(jq -r 'select(.type=="pipeline.aborted") | .data.reason' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "[#2111] pipeline.aborted reason=llm_rate_limited" "llm_rate_limited" "$abort_reason"
assert_contains "[#2111] the abort event carries the reset text" \
    "$(jq -c 'select(.type=="pipeline.aborted")' "$EVENTS_JSONL" 2>/dev/null | head -1)" "resets 3pm"
assert_eq "[#2111] build ran exactly once — no immediate re-dispatch" "1" "$(grep -c 'build ran' "$ZBUILD_TEST_DISPATCH_LOG" || true)"
assert_eq "[#2111] the test member was never dispatched after the rate-limited build" "0" "$(grep -c 'test ran' "$ZBUILD_TEST_DISPATCH_LOG" || true)"
assert_eq "[#2111] no second cycle iteration" "0" "$(jq -c 'select(.type=="cycle.iteration.complete" and .data.cycle_id=="build_test_cycle" and .data.iter=="2")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
state_reason="$(jq -r '.reason // empty' "$STATE_DIR/pipeline-state.json" 2>/dev/null || true)"
assert_eq "[#2111] pipeline-state.json records reason=llm_rate_limited (ADR-050 resume reads status=aborted)" "llm_rate_limited" "$state_reason"
assert_eq "[#2111] pipeline-state.json status=aborted" "aborted" "$(jq -r '.status // empty' "$STATE_DIR/pipeline-state.json" 2>/dev/null || true)"
assert_eq "[#2111] the runner exits 9 (the llm-abort rc, #1024) — not 0, not 4" "9" "${_RUNNER_RC:-}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
