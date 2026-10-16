#!/usr/bin/env bash
# Integration: #1044 / #1188 — acceptance-gate verdict=fail behavior at cycle end.
# When the acceptance-gate writes verdict=fail with a TERMINAL (genuine-violation)
# class (no_testfile / malformed_acceptance_block; #1585/#2097 moved the rest), the build_test_cycle
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

# #1921 follow-up: the runner resolves repo_root from CWD, so a --goal run
# started from the working checkout snapshots zbuild/state/goal-<hash> into it.
# Measured in an isolated clone: a full suite went from 0 state refs to 2, both
# goal refs, and this file produced one of them. The issue-keyed sweep missed
# these because it looked for issue identity.
_ZB_REPO="$(zb_test_repo cycle-acc-term)"

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
# #2366: the stubs write their result with the engine's writer.
export STAGE_RESULT_LIB="$REPO_ROOT/scripts/lib/stage-result.sh"

_make_plugin() {
    local id="$1" role="${2:-}" rc="${3:-0}"
    # #1850/#2366: a stage stub (result_contract 3, JSON primary, a result that
    # says pass on rc 0 and broken otherwise) — mock_plugin_factory's.
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
  result_contract: 3
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
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
design_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '# Design\n```scope\nf.txt\n```\n' > "$state_dir/artifacts/design.md"
    source "$STAGE_RESULT_LIB"
    stage_result_write "$state_dir/artifacts/design-verdict.json" pass "stub design"
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
  result_contract: 3
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
    source "$STAGE_RESULT_LIB"
    stage_result_add "$state_dir/artifacts/plan.json" pass "stub plan"
    return 0
}
PLUG
}

# #2372: the acceptance check runs inside test, which carries its severity into
# test's own result. This stub plays test: a configurable acceptance failure
# (ZBUILD_TEST_GATE_FAILURE) → outcome fail with that severity. Empty → pass.
_make_test_plugin_with_acceptance() {
    local dir="$PLUGINS_ROOT/agent/test"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: test
name: Test test (with the acceptance check)
kind: agent
version: 0.0.1
hooks:
  run: test_stage_run
requires:
  core:
    - redaction
provides:
  role: tester
  result_contract: 3
outputs:
  - id: test_results
    path: ${artifact_dir}/test-results.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
test_stage_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    local f="${ZBUILD_TEST_GATE_FAILURE:-}"
    source "$STAGE_RESULT_LIB"
    if [[ -z "$f" ]]; then
        printf '{"severity":"none","failures":[]}' > "$state_dir/artifacts/test-results.json"
        stage_result_add "$state_dir/artifacts/test-results.json" pass "no failures"
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
    printf '{"severity":"%s","failures":["%s"]}' "$disp" "$f" \
        > "$state_dir/artifacts/test-results.json"
    # #2368: like the real gate, a check it could only not measure is a pass.
    if [[ "$disp" == advisory ]]; then
        stage_result_add "$state_dir/artifacts/test-results.json" pass "$f"
        return 0
    fi
    stage_result_add "$state_dir/artifacts/test-results.json" fail "$f"
    return 0
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
  result_contract: 3
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
    printf '{"schema_version":1,"summary":"ok"}' > "$state_dir/artifacts/design-gate.json"
    source "$STAGE_RESULT_LIB"
    stage_result_add "$state_dir/artifacts/design-gate.json" pass "stub"
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
_make_plugin "hydrate"         "hydrate"
_make_plugin "intake"          "intake"
_make_plan_plugin
_make_design_plugin
_make_design_gate_plugin       # passes so design_verify_cycle converges quickly
# #2187: build_test_cycle's newer members. Unresolved, each was a silent
# `broken` the cycle absorbed; `broken`/`misconfigured` now halt the run.
_make_plugin "spec-coverage"       "spec_coverage"
_make_plugin "test-author"         "test_author"
_make_plugin "assertion-integrity" "assertion_integrity"
_make_plugin "issue-acceptance"    "issue_acceptance"   # #1849
_make_plugin "build"           "builder"
_make_plugin "shape-floor"     "shape_floor"
_make_test_plugin_with_acceptance
_make_plugin "secret-scan"     "secret_scan"
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
# #2191-class flake: the three scenarios used ONE goal back to back, so a run
# could be refused (ADR-059 §4, one run per identity) while the previous run's
# lingering child still held the lock on a loaded runner — no pipeline.end at
# all. Independent scenarios get independent identities. A run that still ends
# without pipeline.end prints why.
_run_pipeline() {   # <scenario>
    : > "$EVENTS_JSONL"
    set +e
    ( cd "$_ZB_REPO" && bash "$REPO_ROOT/core/pipeline/runner.sh" \
        --goal "$(zb_test_goal "acceptance-terminal-${1:-run}")" \
        --template simple \
        --no-resume \
        >"$TEST_TEMP_DIR/runner.stdout" \
        2>"$TEST_TEMP_DIR/runner.stderr" )
    set -e
    if ! jq -e 'select(.type=="pipeline.end")' "$EVENTS_JSONL" >/dev/null 2>&1; then
        echo "--- ${1:-run}: no pipeline.end; events: $(jq -r .type "$EVENTS_JSONL" 2>/dev/null | tail -5 | tr '\n' ' ')" >&2
        tail -20 "$TEST_TEMP_DIR/runner.stderr" >&2 2>/dev/null || true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-4] review approves but acceptance-gate writes a TERMINAL failure
#          (inert_wiring) → pipeline.end status=failed, NOT complete/success.
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T1 [SPEC-4]: terminal acceptance failure (inert_wiring) halts cycle (rc=8)"

export ZBUILD_TEST_GATE_FAILURE="inert_wiring:config/x.yaml"
_run_pipeline t1

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
assert_eq "T1 [SPEC-4]: terminal_failure event names the failing member (test, #2372)" "test" "$term_member"

# The cycle status written to durable state must NOT be complete.
cyc_complete="$(jq -c 'select(.type=="cycle.complete" and .data.cycle_id=="build_test_cycle" and .data.reason=="converged")' \
    "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T1 [SPEC-4]: build_test_cycle did NOT converge (no reason=converged)" "0" "$cyc_complete"

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-2] untagged_spec-only failure is RECOVERABLE — must NOT hard-abort.
#          The loop goes round again to fix it. (#2368: it used to converge
#          only because this test's own gate-aggregator stub passed everything;
#          the real one, and now the engine, keep a failing gate from passing.)
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T2 [SPEC-2]: untagged_spec-only acceptance failure does NOT halt — the loop goes round"

export ZBUILD_TEST_GATE_FAILURE="untagged_spec:SPEC-1"
_run_pipeline t2

end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
rounds="$(jq -c 'select(.type=="cycle.iteration.complete" and .data.cycle_id=="build_test_cycle")' \
    "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_gt "T2 [SPEC-2]: build_test_cycle goes round again (more than one round)" "$rounds" "1"

# No terminal-failure event for the recoverable class.
term_evt="$(jq -c 'select(.type=="cycle.member.terminal_failure")' \
    "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T2 [SPEC-2]: cycle.member.terminal_failure NOT emitted for untagged_spec" "0" "$term_evt"

# ─────────────────────────────────────────────────────────────────────────────
# [SPEC-5] infra failure (negctl_error:timeout) is NON-terminal (ADR-036 #1188).
#          A flaky/slow sandbox must NOT hard-fail the pipeline — the gate
#          reports pass (#2368), the cycle converges → status=success, and NO
#          terminal-failure event fires.
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "T3 [SPEC-5]: infra negctl_error:timeout does NOT halt (status=success)"

export ZBUILD_TEST_GATE_FAILURE="negctl_error:timeout:SPEC-1"
_run_pipeline t3

end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T3 [SPEC-5]: pipeline.end status=success on negctl_error:timeout (infra non-terminal)" "success" "$end_status"

term_evt="$(jq -c 'select(.type=="cycle.member.terminal_failure")' \
    "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T3 [SPEC-5]: cycle.member.terminal_failure NOT emitted for infra timeout" "0" "$term_evt"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
