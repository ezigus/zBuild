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

# #1921 follow-up: the runner resolves repo_root from CWD, so a --goal run
# started from the working checkout snapshots zbuild/state/goal-<hash> into it.
# Measured in an isolated clone: a full suite went from 0 state refs to 2, both
# goal refs, and this file produced one of them. The issue-keyed sweep missed
# these because it looked for issue identity.
_ZB_REPO="$(zb_test_repo cycle-on-max)"
_ZB_GOAL="$(zb_test_goal on-max-continue)"

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
# #979: standard.yaml retired → drive the shipped default simple.yaml. The
# on_max=continue continue-past-exhaustion mechanic is identical; simple.yaml's
# design_verify_cycle (on_max=continue) is the exhausting cycle here, forced by a
# design-gate stub that never returns verdict=pass. All other stages succeed so
# the runner walks past the exhausted cycle to impact → build_test_cycle →
# review_lenses → pr and ends status=success.
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

# Override design-gate to ALWAYS emit verdict=fail via its primary artifact
# (so design_verify_cycle exit_when on design-gate.verdict==pass never matches,
# exhausting max_iterations with on_max=continue — the exhaustion under test).
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
    printf '{"schema_version":1,"verdict":"fail","summary":"forced fail to test max_iterations"}' \
        > "$state_dir/artifacts/design-gate.json"
    return 0
}
PLUG
}

# Override gate-aggregator to ALWAYS emit verdict=pass via its primary artifact
# (so build_test_cycle exit_when on gate-aggregator.verdict==pass converges).
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

# Stubs for every role simple.yaml needs.
# #1074: hydrate is the FIRST stage in simple.yaml. This test enumerates the
# roster, and the runner's resolvability preflight refuses to start when any
# leaf has no plugin — so without this stub the pipeline aborts before intake
# and every assertion below fails for a reason unrelated to what it tests.
_make_plugin "hydrate"         "hydrate"
_make_plugin "intake"          "intake"
_make_plan_plugin
_make_design_plugin
_make_design_gate_plugin   # forces design_verify_cycle to exhaust
# #1683: spec-coverage joined design_verify_cycle. Unresolved, the cycle
# reports reason='blocked' at iter 1 instead of exhausting, and every
# assertion below fails for a reason unrelated to on_max=continue.
_make_plugin "spec-coverage"   "spec_coverage"
_make_plugin "impact"          "impact_analyzer"
_make_plugin "build"           "builder"
_make_plugin "test"            "tester"
# Decomposed mechanical gates (ADR-040) — all pass so build_test_cycle converges.
_make_plugin "shape-floor"     "shape_floor"
_make_plugin "acceptance-gate" "acceptance_gate"
_make_plugin "secret-scan"     "secret_scan"
_make_gate_aggregator_plugin   # emits primary verdict=pass → cycle converges
# review_lenses is now a map group (#1295): one plugin for role review_lens
# handles all elements (security, performance, red-team, correctness, scope).
_make_plugin "review-lens"      "review_lens"
_make_plugin "review-aggregator" "review_aggregator"
_make_plugin "pr"              "pr"

# ─── Drive runner.sh end-to-end with --template simple ────────────────────
: > "$EVENTS_JSONL"

# Operator override token so intake's scope-precondition passes.
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# We bypass intake by skipping the issue fetch — drive with --goal so it
# doesn't try to gh-CLI an issue.
RUNNER_STDERR="$TEST_TEMP_DIR/runner.stderr"
# Assert the throwaway repo before the subshell: without this a failed cd would
# be captured in runner_rc and read as a runner exit code rather than a setup
# failure.
[[ -d "$_ZB_REPO" ]] || { echo "zb_test_repo did not produce a repo" >&2; exit 1; }
set +e
( cd "$_ZB_REPO" && bash "$REPO_ROOT/core/pipeline/runner.sh" \
    --goal "$_ZB_GOAL" \
    --template simple \
    --no-resume \
    >"$TEST_TEMP_DIR/runner.stdout" \
    2>"$RUNNER_STDERR" )
# shellcheck disable=SC2034  # captured so `set -e` below cannot swallow a
# non-zero runner exit before the assertions run; the test asserts on the event
# stream rather than the rc. Pre-existing, kept deliberately.
runner_rc=$?
set -e

print_test_section "T1: events.jsonl chain around design_verify_cycle exhaustion"

# T1.1: cycle.complete fired with a non-convergence terminal reason for
# design_verify_cycle. Accept any of {max_iterations, plateau, divergence} —
# the test's intent (per #766) is to verify the runner continues past
# cycle exit, NOT to pin a specific reason.
mi_count="$(jq -c 'select(.type=="cycle.complete" and (.data.reason=="max_iterations" or .data.reason=="plateau" or .data.reason=="divergence") and .data.cycle_id=="design_verify_cycle")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$mi_count" -ge 1 ]] \
    && assert_pass "T1.1: cycle.complete fired with non-convergence reason for design_verify_cycle (count=$mi_count)" \
    || assert_fail "T1.1: cycle.complete MUST fire with non-convergence reason" "count=$mi_count"

# T1.2: cycle.unconverged event MUST be emitted (proves runner.sh:1292 reached)
unconv_count="$(jq -c 'select(.type=="cycle.unconverged" and .data.cycle_id=="design_verify_cycle")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T1.2: cycle.unconverged event emitted (proves runner continues past cycle exit)" "1" "$unconv_count"

# T1.3: pipeline.abort (EXIT trap) MUST NOT fire on the on_max=continue path
abort_count="$(jq -c 'select(.type=="pipeline.abort")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T1.3: pipeline.abort MUST NOT fire on on_max=continue cycle exhaustion" "0" "$abort_count"

# T1.4: pipeline.end emitted exactly once
end_count="$(jq -c 'select(.type=="pipeline.end")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T1.4: pipeline.end emitted exactly once" "1" "$end_count"

# T1.5 (#979 COUPLING FINDING): under the retired standard.yaml this asserted
# status=success — #796/ADR-021 v3 R1 "rescued" an unconverged on_max=continue run
# to success when the terminal `review` stage approved. That rescue path is engine
# code (core/pipeline/runner.sh) that hardcodes reading artifacts/review.json:
#     _review_json="$(dirname "$state_file")/artifacts/review.json"
#     case "$_review_verdict" in approve|pass) _downstream_success=1 ;; ...
# simple.yaml has NO `review` stage (its advisory review_lenses group writes no
# review.json), so no review.json exists → _downstream_success=0 → status=failed.
# This test does NOT edit core/pipeline (EPIC #1277 / #979 guardrail); it asserts
# the ACTUAL current engine behavior. The review.json-rescue branch is now dead
# code coupled to the retired lattice — reported as a #979 coupling finding for a
# follow-up (generalize the rescue to the template's terminal-stage verdict, or
# drop it). The #766 mechanic under test (unconverged on_max=continue → NO
# pipeline.abort, runner CONTINUES past the cycle) is fully proven by T1.1–T2.2.
end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T1.5 (#979): pipeline.end status=failed (no review.json rescue under simple.yaml; see coupling note)" "failed" "$end_status"

print_test_section "T2: build_test_cycle + pr dispatched after design_verify_cycle exhausted"

# T2.1: build_test_cycle entered (build runs at least once because the inner
# build_test_cycle dispatches after the exhausted design_verify_cycle).
build_run_count="$(jq -c 'select(.type=="plugin.run.start" and .data.plugin=="build")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$build_run_count" -ge 1 ]] \
    && assert_pass "T2.1: build plugin ran (proves build_test_cycle was dispatched after design_verify_cycle exhausted)" \
    || assert_fail "T2.1: build plugin did NOT run (runner stopped before build_test_cycle)" "build_run_count=$build_run_count"

# T2.2 (#979): the retired standard.yaml had a merge-blocking `review` member; simple.yaml
# ends with the pr tool stage after the advisory review_lenses group. Assert pr ran —
# it proves the runner walked ALL THE WAY to the terminal stage after the cycle exhausted.
pr_run_count="$(jq -c 'select(.type=="plugin.run.start" and .data.plugin=="pr")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$pr_run_count" -ge 1 ]] \
    && assert_pass "T2.2: pr plugin ran (proves the pipeline reached its terminal stage past the exhausted cycle)" \
    || assert_fail "T2.2: pr plugin did NOT run" "pr_run_count=$pr_run_count"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
