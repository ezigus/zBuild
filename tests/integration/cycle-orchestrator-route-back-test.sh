#!/usr/bin/env bash
# [S3/S6] Integration (#1217, ADR-045): route_back cycle terminal.
#
# route_back is a CONTINUE-with-bounded-rewind terminal (rc=11, reason
# route_back) — NOT a halt. It fires ONLY on a correctable non-clean terminal
# (rc=2 unconverged / rc=8 member_terminal_failure) when the predicate matches.
# The orchestrator stashes the fallback rc + target for the runner and returns
# 11. When no route_back is declared the orchestrator NEVER yields 11
# (forward-only, unchanged). A clean converge (rc=0) never reroutes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — route_back (#1217 / ADR-045)"
setup_test_env "cycle-orch-route-back"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

_seed_state() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
}

# Template WITH route_back: plan is an earlier top-level stage; the cycle routes
# back to it when test.verdict==retry. max_iterations low so it exhausts fast.
RB_TPL="$TEST_TEMP_DIR/rb.yaml"
cat > "$RB_TPL" <<'EOF'
id: rb-orch
defaults:
  strategy: fanout
flow:
  - plan
  - bt_cycle
plan:
  roles: [planner]
bt_cycle:
  type: cycle
  flow:
    - build
    - test
  exit_when:
    stage: test
    field: verdict
    op: eq
    value: pass
  route_back:
    to: plan
    when:
      stage: test
      field: verdict
      op: eq
      value: retry
    max: 2
  max_iterations: 2
  on_max: continue
build:
  roles: [builder]
test:
  roles: [tester]
EOF

# ── T1: predicate matches → rc=11 route_back ────────────────────────────────
# test always emits verdict=retry (status complete, rc 0 → NOT a hard-fail):
# exit_when(pass) never matches, so the cycle exhausts max_iterations with tests
# "passing" → correctable rc=2 → route_back guard converts it to rc=11.
cycle_dispatch_stage() {
    local stage="$1"
    _CYCLE_DISPATCH_STATUS="complete"
    case "$stage" in
        build) _CYCLE_DISPATCH_VERDICT="pass" ;;
        test)  _CYCLE_DISPATCH_VERDICT="retry" ;;
    esac
    return 0
}

_TPL_STAGES=(); _TPL_CYCLES=()
set +e; load_template "$RB_TPL"; rc=$?; set -e
assert_eq "T1: template loads rc=0" "0" "$rc"

_seed_state
_CYCLE_ROUTE_BACK_TO=""; _CYCLE_ROUTE_BACK_FALLBACK_RC=""
set +e; cycle_orchestrator_run "bt_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T1: orchestrator returns rc=11 route_back" "11" "$rc"
assert_eq "T1: reason=route_back" "route_back" "$_CYCLE_LAST_TERMINATED_REASON"
assert_eq "T1: stashed route_back target=plan" "plan" "$_CYCLE_ROUTE_BACK_TO"
assert_eq "T1: stashed fallback rc=2 (correctable unconverged)" "2" "$_CYCLE_ROUTE_BACK_FALLBACK_RC"
# cycle.complete restated with reason=route_back (rc=11 → reason mapping).
_cnt="$(grep -c '"type":"cycle.complete".*"reason":"route_back"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
[[ -z "$_cnt" ]] && _cnt=0
assert_gt "T1: cycle.complete reason=route_back emitted" "$_cnt" "0"
# predicate event with kind=route_back.
_pcnt="$(grep -c '"kind":"route_back"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
[[ -z "$_pcnt" ]] && _pcnt=0
assert_gt "T1: route_back predicate event emitted" "$_pcnt" "0"

# ── T2 [S3]: converge (test=pass) → rc=0, NEVER reroutes ────────────────────
cycle_dispatch_stage() {
    local stage="$1"
    _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_VERDICT="pass"
    return 0
}
_seed_state
set +e; cycle_orchestrator_run "bt_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T2 [S3]: converged cycle returns rc=0 (route_back declared but not fired)" "0" "$rc"

# ── T3 [S3]: no route_back declared → NEVER yields 11 (forward-only) ────────
# NOTE: distinct cycle id (bt2) so the prior template's route_back exports
# cannot leak in — load_template does not scrub per-cycle predicate vars (same
# as abort_when), and this cycle genuinely declares no route_back.
NORB_TPL="$TEST_TEMP_DIR/norb.yaml"
cat > "$NORB_TPL" <<'EOF'
id: norb-orch
defaults:
  strategy: fanout
flow:
  - plan
  - bt2
plan:
  roles: [planner]
bt2:
  type: cycle
  flow:
    - build
    - test
  exit_when:
    stage: test
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
build:
  roles: [builder]
test:
  roles: [tester]
EOF
# test=retry → exhausts, tests passing → rc=2 unconverged (NO reroute).
cycle_dispatch_stage() {
    local stage="$1"
    _CYCLE_DISPATCH_STATUS="complete"
    case "$stage" in
        build) _CYCLE_DISPATCH_VERDICT="pass" ;;
        test)  _CYCLE_DISPATCH_VERDICT="retry" ;;
    esac
    return 0
}
_TPL_STAGES=(); _TPL_CYCLES=()
set +e; load_template "$NORB_TPL"; rc=$?; set -e
assert_eq "T3: no-route_back template loads rc=0" "0" "$rc"
_seed_state
set +e; cycle_orchestrator_run "bt2" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T3 [S3]: no route_back → orchestrator returns rc=2, NEVER 11" "2" "$rc"

# ── T4: _cycle_handle_terminal_rc maps rc=11 → reason=route_back ─────────────
_seed_state
_CYCLE_LAST_ITERATIONS=1
_cycle_handle_terminal_rc 11 "bt_cycle" "$STATE_FILE"
_m="$(grep -c '"type":"cycle.complete".*"reason":"route_back"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
[[ -z "$_m" ]] && _m=0
assert_gt "T4: _cycle_handle_terminal_rc 11 emits cycle.complete reason=route_back" "$_m" "0"

print_test_results
