#!/usr/bin/env bash
# Integration: ADR-063 §4 (review on PR #2262) — a gate member that reports
# `unavailable` ENDS the run, even when its verdict reads as a pass.
# The issue-acceptance stub (a convergence gate in build_test_cycle) writes a v2
# result with verdict pass, disposition unavailable, and returns 0 — the shape a
# failed model call takes when part of a reply still parses. Every other member
# passes, so if the engine read the verdict and ignored the disposition the
# cycle would go on to gate-aggregator and converge. Instead the engine must
# halt on halt_unavailable (ADR-054 §6, #2111): gate-aggregator never runs, the
# cycle does not converge, the run ends pipeline.end status=aborted with
# pipeline.aborted reason=llm_unavailable, and the runner exits 9.
# This is why `unavailable` is not one of disposition_unfinished's words: it is
# not retried, so a cycle never reaches convergence on it.
# Real runner (core/pipeline/runner.sh --template simple) over stub plugins.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-063 §4: a gate that reports unavailable ends the run — it does not converge"
setup_test_env "cycle-gate-unavailable-aborts"

# #1921 follow-up: the runner resolves repo_root from CWD, so a --goal run
# started from the working checkout snapshots zbuild/state/goal-<hash> into it.
# Measured in an isolated clone: a full suite went from 0 state refs to 2, both
# goal refs, and this file produced one of them. The issue-keyed sweep missed
# these because it looked for issue identity.
_ZB_REPO="$(zb_test_repo cycle-gate-unavailable)"
_ZB_GOAL="$(zb_test_goal gate-unavailable-abort)"

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
    # #1850: a v2 stage stub (result_contract 2, JSON primary, a v2 result that
    # says pass on rc 0 and error/broken otherwise) — mock_plugin_factory's.
    mock_plugin_factory "$id" agent "$rc" "" "$role" >/dev/null
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
  result_contract: 2
outputs:
  - id: design_out
    path: ${artifact_dir}/design.md
    type: text/markdown
    required: true
  - id: design_result
    path: ${artifact_dir}/design-verdict.json
    type: json
    required: true
    primary: true
config:
  valid_verdicts: [pass, error, incomplete]
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
design_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '# Design\n```scope\nf.txt\n```\n' > "$state_dir/artifacts/design.md"
    printf '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"stub design"}' \
        > "$state_dir/artifacts/design-verdict.json"
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
  result_contract: 2
outputs:
  - id: plan_out
    path: ${artifact_dir}/plan.json
    type: json
    required: true
    primary: true
config:
  valid_verdicts: [pass, error]
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
plan_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"stub plan","schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["f.txt"],"estimated_lines":1}],"estimated_total_lines":1,"notes":""}' \
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
  result_contract: 2
outputs:
  - id: gate_result
    path: ${artifact_dir}/acceptance-gate-result.json
    type: json
    required: true
    primary: true
config:
  valid_verdicts: [pass, fail]
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
acceptance_gate_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    local f="${ZBUILD_TEST_GATE_FAILURE:-}"
    if [[ -z "$f" ]]; then
        printf '{"result_contract":2,"verdict":"pass","disposition":"complete","severity":"none","reason":"no failures","failures":[]}' \
            > "$state_dir/artifacts/acceptance-gate-result.json"
        return 0
    fi
    # Mirror the real gate's class→severity mapping (ADR-021 / ADR-036): the
    # engine reads ONLY this generic severity field (#2161), not the failure class.
    local disp
    case "$f" in
        untagged_spec:*)                        disp="recoverable" ;;
        negctl_error:* | reachability_error:*)  disp="advisory" ;;
        *)                                      disp="terminal" ;;
    esac
    printf '{"result_contract":2,"verdict":"fail","disposition":"complete","severity":"%s","reason":"%s","failures":["%s"]}' "$disp" "$f" "$f" \
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
  result_contract: 2
outputs:
  - id: design_gate_out
    path: ${artifact_dir}/design-gate.json
    type: json
    required: true
    primary: true
config:
  valid_verdicts: [pass, fail]
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
design_gate_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"result_contract":2,"disposition":"complete","reason":"stub","schema_version":1,"verdict":"pass","summary":"ok"}' \
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
  result_contract: 2
outputs:
  - id: gate_aggregator_out
    path: ${artifact_dir}/gate-aggregator.json
    type: json
    required: true
    primary: true
config:
  valid_verdicts: [pass, fail]
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
gate_aggregator_run() {
    local state_dir; state_dir="$(dirname "$2")"
    printf 'gate-aggregator ran\n' >> "${ZBUILD_TEST_DISPATCH_LOG:?}"
    mkdir -p "$state_dir/artifacts"
    printf '{"result_contract":2,"disposition":"complete","reason":"stub","schema_version":1,"verdict":"pass","summary":"ok","gates":[]}' \
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

# issue-acceptance: the model call failed (disposition unavailable), yet the
# result carries a passing verdict and the stage returns 0.
_make_unavailable_issue_acceptance_plugin() {
    local dir="$PLUGINS_ROOT/agent/issue-acceptance"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: issue-acceptance
name: Test issue-acceptance (unavailable)
kind: agent
version: 0.0.1
hooks:
  run: issue_acceptance_run
requires:
  core:
    - redaction
provides:
  role: issue_acceptance
  result_contract: 2
outputs:
  - id: issue_acceptance_result
    path: ${artifact_dir}/issue-acceptance-result.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
issue_acceptance_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '%s\n' '{"result_contract":2,"verdict":"pass","disposition":"unavailable","reason":"router_rc_nonzero","data":{}}' \
        > "$state_dir/artifacts/issue-acceptance-result.json"
    printf 'issue-acceptance ran\n' >> "${ZBUILD_TEST_DISPATCH_LOG:?}"
    return 0
}
PLUG
}

_make_plugin "hydrate"         "hydrate"
_make_plugin "intake"          "intake"
_make_plan_plugin
_make_design_plugin
_make_design_gate_plugin       # passes so design_verify_cycle converges quickly
# #2187: build_test_cycle's newer members. Unresolved, each was a silent
# `broken` the cycle absorbed; `broken`/`misconfigured` now halt the run.
_make_plugin "spec-coverage"       "spec_coverage"
_make_plugin "test-author"         "test_author"
_make_plugin "spec-correspondence" "spec_correspondence"
_make_plugin "assertion-integrity" "assertion_integrity"
_make_unavailable_issue_acceptance_plugin
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
# The run ends on the unavailable gate: aborted, resumable, not converged.
# ─────────────────────────────────────────────────────────────────────────────

export ZBUILD_TEST_DISPATCH_LOG="$TEST_TEMP_DIR/dispatch.log"; : > "$ZBUILD_TEST_DISPATCH_LOG"

print_test_section "[ADR-063 §4] a gate reporting unavailable with a passing verdict ends the run; the cycle does not converge"
_run_pipeline
assert_eq "[ADR-063 §4] the unavailable gate ran exactly once — it is not retried" \
    "1" "$(grep -c 'issue-acceptance ran' "$ZBUILD_TEST_DISPATCH_LOG" || true)"
assert_eq "[ADR-063 §4] gate-aggregator never ran — the cycle did not reach its convergence check" \
    "0" "$(grep -c 'gate-aggregator ran' "$ZBUILD_TEST_DISPATCH_LOG" || true)"
assert_eq "[ADR-063 §4] the engine announced the halt on unavailable for issue-acceptance" "1" \
    "$(jq -c 'select(.type=="cycle.member.disposition.halt" and .data.member=="issue-acceptance" and .data.disposition=="unavailable")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "[ADR-063 §4] pipeline.end status=aborted (not success: the cycle did not converge)" "aborted" "$end_status"
abort_reason="$(jq -r 'select(.type=="pipeline.aborted") | .data.reason' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "[ADR-063 §4] pipeline.aborted reason=llm_unavailable" "llm_unavailable" "$abort_reason"
assert_eq "[ADR-063 §4] pipeline-state.json status=aborted (resumable, ADR-050)" "aborted" \
    "$(jq -r '.status // empty' "$STATE_DIR/pipeline-state.json" 2>/dev/null || true)"
# #1850 (ADR-054 §4): was 9 (the llm-abort rc). Every halt exits 1; the
# llm_unavailable word above (event + state) is what says why.
assert_eq "[ADR-063 §4] the runner exits 1 — not 0, not the old llm-abort rc 9" "1" "${_RUNNER_RC:-}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
