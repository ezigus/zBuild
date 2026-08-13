#!/usr/bin/env bash
# Integration: ADR-039 (#1132, amends ADR-021) — parallel group as a cycle member.
#
# A cycle whose flow names a `type: parallel` group runs the group concurrently
# each iteration; the group aggregate verdict keys the cycle verdict blob, so the
# cycle exit_when can reference the group id. Asserts:
#   - the template loads and folds to a single "cycle:<id>" dispatch unit (the
#     in-cycle group does NOT emit a stray top-level "parallel:<gid>" unit)
#   - both group members dispatch each iteration (concurrent, via parallel_group_run)
#   - the group verdict drives exit_when: iter-1 member failure → group fail →
#     cycle iterates; iter-2 all pass → group pass → cycle converges on iter 2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — parallel group as member (ADR-039, #1132)"
setup_test_env "cycle-parallel-member"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# cycle-orchestrator.sh sources template.sh + parallel-orchestrator.sh.
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, stage_verdicts:{}, updated_at:"seed"}' > "$STATE_FILE"

# New-shape fixture: a cycle whose only flow member is a parallel group. The
# group members (build, test) are canonical leaf stages declared top-level. The
# cycle exit_when references the GROUP id "gates".
TPL="$TEST_TEMP_DIR/cycle-parallel.yaml"
cat > "$TPL" <<'EOF'
id: cycle-parallel
name: Cycle With Parallel Member
defaults:
  strategy: fanout

flow:
  - build_gate_cycle

build_gate_cycle:
  type: cycle
  flow:
    - gates
  exit_when:
    stage: gates
    field: verdict
    op: eq
    value: pass
  max_iterations: 3
  on_max: continue

gates:
  type: parallel
  flow:
    - build
    - test
  max_parallel: 2
  on_member_error: collect

build:
  roles: [builder]

test:
  roles: [tester]
EOF

# cycle_dispatch_stage is required to exist by the orchestrator's pre-flight
# guard even when no LEAF member is dispatched directly (the sole member is the
# parallel group). Fail loudly if it is ever called — it must not be.
cycle_dispatch_stage() {
    printf 'UNEXPECTED leaf dispatch: %s\n' "$1" >&2
    _CYCLE_DISPATCH_VERDICT="error"; _CYCLE_DISPATCH_STATUS="failed"
    return 1
}

# Parallel member dispatch hook. Records that each member ran this iteration
# (per-member marker files — NO concurrent appends to a shared log). build
# "fails" only on iteration 1, so the group verdict is fail→pass across iters,
# driving the cycle to converge on iteration 2 via exit_when.
RAN_DIR="$TEST_TEMP_DIR/ran"; rm -rf "$RAN_DIR"; mkdir -p "$RAN_DIR"
parallel_dispatch_stage() {
    local member="$1"
    : > "$RAN_DIR/${member}.iter${ZBUILD_CYCLE_ITER:-0}"
    if [[ "$member" == "build" && "${ZBUILD_CYCLE_ITER:-1}" == "1" ]]; then
        _PARALLEL_DISPATCH_VERDICT="fail"; _PARALLEL_DISPATCH_STATUS="failed"
        return 1
    fi
    _PARALLEL_DISPATCH_VERDICT="pass"; _PARALLEL_DISPATCH_STATUS="complete"
    return 0
}

_TPL_STAGES=()
_TPL_CYCLES=()
_TPL_PARALLEL_GROUPS=()

# ── T1: template loads; the parallel group folds under the cycle dispatch unit.
print_test_section "T1: load + dispatch-unit folding"
set +e
load_template "$TPL"; rc=$?
set -e
assert_eq "T1: template loads rc=0" "0" "$rc"
assert_eq "T1: group registered (_TPL_PARALLEL_GROUPS)" "gates" "${_TPL_PARALLEL_GROUPS[*]}"
assert_eq "T1: cycle registered (_TPL_CYCLES)" "build_gate_cycle" "${_TPL_CYCLES[*]}"
# Single cycle unit — no stray "parallel:gates" (the group folds into the cycle).
assert_eq "T1: one dispatch unit = cycle:build_gate_cycle" \
    "cycle:build_gate_cycle" "${_TPL_DISPATCH_UNITS[*]}"
# The group's leaf members are flattened into _TPL_STAGES.
assert_contains "T1: _TPL_STAGES includes build" "${_TPL_STAGES[*]}" "build"
assert_contains "T1: _TPL_STAGES includes test" "${_TPL_STAGES[*]}" "test"
# Parallel discriminator set on the group id.
assert_eq "T1: _TPL_STAGE_TYPE_gates=parallel" "parallel" "${_TPL_STAGE_TYPE_gates:-}"

# ── T2: run the cycle. Group runs each iter; verdict drives exit_when.
print_test_section "T2: cycle runs the group; group verdict drives exit_when"
set +e
cycle_orchestrator_run "build_gate_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?
set -e
assert_eq "T2: cycle rc=0 (converged via group verdict)" "0" "$rc"
assert_eq "T2: terminated reason=converged" "converged" "$_CYCLE_LAST_TERMINATED_REASON"
assert_eq "T2: converged on iteration 2" "2" "$_CYCLE_LAST_ITERATIONS"

# ── T3: both group members dispatched (concurrently) each iteration.
print_test_section "T3: group members dispatched both iterations"
assert_eq "T3: build ran iter 1" "1" "$([[ -f "$RAN_DIR/build.iter1" ]] && echo 1 || echo 0)"
assert_eq "T3: test ran iter 1"  "1" "$([[ -f "$RAN_DIR/test.iter1" ]] && echo 1 || echo 0)"
assert_eq "T3: build ran iter 2" "1" "$([[ -f "$RAN_DIR/build.iter2" ]] && echo 1 || echo 0)"
assert_eq "T3: test ran iter 2"  "1" "$([[ -f "$RAN_DIR/test.iter2" ]] && echo 1 || echo 0)"

# ── T4: parallel + cycle lifecycle events both present (group ran INSIDE cycle).
print_test_section "T4: parallel-group lifecycle events emitted inside the cycle"
assert_event_emitted "T4: cycle.start emitted" "$ZBUILD_EVENTS_JSONL" "cycle.start"
assert_event_emitted "T4: parallel.group.start emitted" \
    "$ZBUILD_EVENTS_JSONL" "parallel.group.start"
assert_event_emitted "T4: parallel.member.dispatch.complete emitted" \
    "$ZBUILD_EVENTS_JSONL" "parallel.member.dispatch.complete"
# 2 iterations × 1 group.start each.
group_starts="$(grep -c '"parallel.group.start"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "T4: 2 parallel.group.start events (one per iter)" "2" "$group_starts"

# ── T5 (#1800): the group's own dispatch record reaches the durable state maps.
# The parallel-group branch of _cycle_iter_dispatch is a third write site,
# distinct from the leaf and nested-cycle paths.
print_test_section "T5: parallel-group member recorded in the durable state maps"
gates_ss="$(jq -r '.stage_statuses.gates // "missing"' "$STATE_FILE")"
assert_eq "[SPEC-3] T5: parallel group recorded in stage_statuses (cycle-member path)" "complete" "$gates_ss"
gates_sv="$(jq -r '.stage_verdicts.gates // "missing"' "$STATE_FILE")"
assert_eq "[SPEC-4] T5: parallel group recorded in stage_verdicts (cycle-member path)" "pass" "$gates_sv"

print_test_results
