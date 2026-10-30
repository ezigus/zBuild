#!/usr/bin/env bash
# Integration: ADR-027 abort_when predicate semantics (Wave 17-B, #703).
#
# abort_when (optional) is a predicate that, when matched, terminates the
# pipeline: the loop returns 1, ends with outcome aborted and reason
# cycle_abort, and records the abort word `cycle_abort` (ADR-025), which every
# enclosing cycle and the runner read on their way out. Distinct from a SIGINT
# abort (word sigint) and from blocked (outcome interrupted, no abort word).
#
# #1850 (ADR-054 §4): this used to be a new rc class, rc=6. No rc carries the
# reason any more — the word does.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — abort_when (ADR-027 / Wave 17-B)"
setup_test_env "cycle-orch-abortwhen"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

ABORT_TPL="$TEST_TEMP_DIR/abort.yaml"
cat > "$ABORT_TPL" <<'EOF'
id: abort-test
name: abort_when test
defaults:
  strategy: fanout

flow:
  - bt_cycle

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
  abort_when:
    stage: test
    field: verdict
    op: eq
    value: corrupt
  max_iterations: 5
  on_max: continue

build:
  roles: [builder]

test:
  roles: [tester]
EOF

# Mock: build always passes; test returns "corrupt" on iter 1 (trigger abort).
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    case "$stage" in
        build) _CYCLE_DISPATCH_VERDICT="pass" ;;
        test)  _CYCLE_DISPATCH_VERDICT="corrupt"
               _CYCLE_DISPATCH_STATUS="failed"
               return 1
               ;;
    esac
    return 0
}

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=()
_TPL_CYCLES=()
set +e
load_template "$ABORT_TPL"; rc=$?
set -e
assert_eq "T1: template loads rc=0" "0" "$rc"

set +e
cycle_orchestrator_run "bt_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"
rc=$?
set -e

# T2: rc=1 with outcome aborted — the word, not a number, says cycle_abort.
assert_eq "T2: orchestrator returns rc=1, outcome aborted" "1 aborted" "$rc ${_CYCLE_LAST_OUTCOME:-unset}"

# T3: terminated reason set.
assert_eq "T3: reason=cycle_abort" "cycle_abort" "$_CYCLE_LAST_TERMINATED_REASON"

# T4: the abort is recorded as the word cycle_abort, so an enclosing
# dispatcher's post-flight check propagates the loop's rc=1 outward.
# shellcheck source=../../scripts/lib/abort-propagation.sh
source "$REPO_ROOT/scripts/lib/abort-propagation.sh"
assert_eq "T4: the recorded abort word is cycle_abort" "cycle_abort" "$(_zbuild_abort_reason)"
set +e
_zbuild_propagate_abort "$rc"; rc2=$?
set -e
assert_eq "T4: _zbuild_propagate_abort on the loop's rc=1 propagates (returns 1)" "1" "$rc2"

# T5: a benign rc is never an abort (smoke check).
set +e
_zbuild_propagate_abort 0; rc3=$?
set -e
assert_eq "T5: rc=0 returns 0 (non-abort)" "0" "$rc3"

# T6 (Copilot P1): structural — the runner ends the run on the recorded abort
# WORD, and no longer branches on rc=6 (#1850). If it still read the number,
# a loop returning 1 for cycle_abort would fall through as an ordinary failed
# cycle and abort_when would silently no-op at the pipeline level. The
# behavior (cycle_abort → status interrupted, pipeline.aborted reason
# cycle_abort) is pinned by runner-cycle-rc-action-mapping-test.sh.
RUNNER_FILE="$REPO_ROOT/core/pipeline/runner.sh"
if grep -qE '_rc -eq 6' "$RUNNER_FILE" 2>/dev/null; then
    assert_fail "T6: runner reads the abort word, not rc=6" \
        "runner.sh still branches on rc=6: $(grep -nE '_rc -eq 6' "$RUNNER_FILE" | tr '\n' ' ')"
elif ! grep -q '_zbuild_abort_reason' "$RUNNER_FILE" 2>/dev/null; then
    assert_fail "T6: runner reads the abort word, not rc=6" \
        "runner.sh never calls _zbuild_abort_reason"
else
    assert_pass "T6: runner reads the abort word, not rc=6"
fi

print_test_section "SPEC-6 — full eight-op set in abort_when evaluator (_cycle_check_abort_when)"
# _cycle_check_abort_when: rc=0 = condition matched (DO abort), rc=1 = no match.
# Set internal abort_when state directly via _cycle_load_template after writing
# the template-level vars, so we bypass load_template op validation.
# Tests FAIL before #1760 because neq/gt/gte/lt/lte/contains/matches are absent
# from _cycle_check_abort_when.

# eq (regression)
_TPL_CYCLE_ABORT_WHEN_STAGE_aw_cycle="s1"
_TPL_CYCLE_ABORT_WHEN_FIELD_aw_cycle="verdict"
_TPL_CYCLE_ABORT_WHEN_OP_aw_cycle="eq"
_TPL_CYCLE_ABORT_WHEN_VALUE_aw_cycle="block"
_TPL_CYCLE_UNTIL_STAGE_aw_cycle="s1"
_TPL_CYCLE_UNTIL_FIELD_aw_cycle="verdict"
_TPL_CYCLE_UNTIL_OP_aw_cycle="eq"
_TPL_CYCLE_UNTIL_VALUE_aw_cycle="pass"
_TPL_CYCLE_STAGES_aw_cycle="s1"
_TPL_STAGE_TYPE_s1="leaf"
_CYCLE_TRAP_CYCLE_ID="aw_cycle"
_CYCLE_TRAP_ITER=1
_cycle_load_template "aw_cycle"

blob='{"s1":{"verdict":"block","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] eq: verdict==block → rc=0 (abort matched)" "0" "$rc"

blob='{"s1":{"verdict":"approve","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] eq: verdict==approve → rc=1 (no match)" "1" "$rc"

# neq
_TPL_CYCLE_ABORT_WHEN_OP_aw_cycle="neq"
_TPL_CYCLE_ABORT_WHEN_VALUE_aw_cycle="pass"
_CYCLE_TRAP_CYCLE_ID="aw_cycle"
_CYCLE_TRAP_ITER=1
_cycle_load_template "aw_cycle"

blob='{"s1":{"verdict":"fail","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] neq: fail!=pass → rc=0 (abort matched)" "0" "$rc"

blob='{"s1":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] neq: pass==pass → rc=1 (no match)" "1" "$rc"

# gt
_TPL_CYCLE_ABORT_WHEN_FIELD_aw_cycle="score"
_TPL_CYCLE_ABORT_WHEN_OP_aw_cycle="gt"
_TPL_CYCLE_ABORT_WHEN_VALUE_aw_cycle="10"
_CYCLE_TRAP_CYCLE_ID="aw_cycle"
_CYCLE_TRAP_ITER=1
_cycle_load_template "aw_cycle"

blob='{"s1":{"score":"15","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] gt: 15>10 → rc=0 (abort matched)" "0" "$rc"

blob='{"s1":{"score":"5","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] gt: 5>10 → rc=1 (no match)" "1" "$rc"

# gte
_TPL_CYCLE_ABORT_WHEN_OP_aw_cycle="gte"
_TPL_CYCLE_ABORT_WHEN_VALUE_aw_cycle="10"
_CYCLE_TRAP_CYCLE_ID="aw_cycle"
_CYCLE_TRAP_ITER=1
_cycle_load_template "aw_cycle"

blob='{"s1":{"score":"10","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] gte: 10>=10 → rc=0 (abort matched)" "0" "$rc"

blob='{"s1":{"score":"9","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] gte: 9>=10 → rc=1 (no match)" "1" "$rc"

# lt
_TPL_CYCLE_ABORT_WHEN_OP_aw_cycle="lt"
_TPL_CYCLE_ABORT_WHEN_VALUE_aw_cycle="5"
_CYCLE_TRAP_CYCLE_ID="aw_cycle"
_CYCLE_TRAP_ITER=1
_cycle_load_template "aw_cycle"

blob='{"s1":{"score":"2","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] lt: 2<5 → rc=0 (abort matched)" "0" "$rc"

blob='{"s1":{"score":"8","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] lt: 8<5 → rc=1 (no match)" "1" "$rc"

# lte
_TPL_CYCLE_ABORT_WHEN_OP_aw_cycle="lte"
_TPL_CYCLE_ABORT_WHEN_VALUE_aw_cycle="5"
_CYCLE_TRAP_CYCLE_ID="aw_cycle"
_CYCLE_TRAP_ITER=1
_cycle_load_template "aw_cycle"

blob='{"s1":{"score":"5","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] lte: 5<=5 → rc=0 (abort matched)" "0" "$rc"

blob='{"s1":{"score":"6","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] lte: 6<=5 → rc=1 (no match)" "1" "$rc"

# contains
_TPL_CYCLE_ABORT_WHEN_FIELD_aw_cycle="reason"
_TPL_CYCLE_ABORT_WHEN_OP_aw_cycle="contains"
_TPL_CYCLE_ABORT_WHEN_VALUE_aw_cycle="corrupt"
_CYCLE_TRAP_CYCLE_ID="aw_cycle"
_CYCLE_TRAP_ITER=1
_cycle_load_template "aw_cycle"

blob='{"s1":{"reason":"data corrupt detected","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] contains: 'data corrupt detected' contains 'corrupt' → rc=0" "0" "$rc"

blob='{"s1":{"reason":"passed","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] contains: 'passed' not contains 'corrupt' → rc=1" "1" "$rc"

# matches
_TPL_CYCLE_ABORT_WHEN_FIELD_aw_cycle="verdict"
_TPL_CYCLE_ABORT_WHEN_OP_aw_cycle="matches"
_TPL_CYCLE_ABORT_WHEN_VALUE_aw_cycle="^block"
_CYCLE_TRAP_CYCLE_ID="aw_cycle"
_CYCLE_TRAP_ITER=1
_cycle_load_template "aw_cycle"

blob='{"s1":{"verdict":"blocked","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] matches: 'blocked' =~ '^block' → rc=0 (abort matched)" "0" "$rc"

blob='{"s1":{"verdict":"approve","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-6] matches: 'approve' =~ '^block' → rc=1 (no match)" "1" "$rc"

print_test_results
