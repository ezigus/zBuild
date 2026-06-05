#!/usr/bin/env bash
# Integration test (Wave 19-B, #718): N-level recursive seq labels via prefix
# accumulation handle arbitrary cycle nesting depth WITHOUT changes to the
# orchestrator.
#
# Builds a 3-level synthetic nested cycle by populating the orchestrator's
# _TPL_* state directly (the template loader's IC| expansion only handles one
# level of cycle-as-member today; this test bypasses that limitation to prove
# the ORCHESTRATOR'S recursion handles arbitrary depth — which is the Wave
# 19-B contract):
#
#   level1_cycle (top)  →  members: [level2_cycle]
#   level2_cycle        →  members: [level3_cycle]
#   level3_cycle        →  members: [build, test, test_assessment]   ← leaves
#
# With ZBUILD_SEQ_PREFIX="3" (simulating the runner publishing the cardinal of
# level1_cycle), the orchestrator must produce 7-segment labels at the leaves
# (prefix accumulates as 3 → 3.1.1 → 3.1.1.1.1 → leaves at 3.1.1.1.1.<iter>.<pos>).
#
# Iter 1 leaves:
#   build           = "3.1.1.1.1.1.1"
#   test            = "3.1.1.1.1.1.2"
#   test_assessment = "3.1.1.1.1.1.3"
#
# This test is THE depth-independence proof — every level uses the same
# dispatch logic in cycle_orchestrator_run; the recursion bottoms out only
# when a member's _TPL_STAGE_TYPE_<id> is `leaf`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle orchestrator deep (3-level) recursive seq labels (#718)"
setup_test_env "cycle-seq-deep-nesting"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
LABEL_LOG="$TEST_TEMP_DIR/labels.log"
: > "$LABEL_LOG"
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# Hand-build _TPL_* state for the 3 nested cycles. (Bypasses load_template's
# 1-level cycle-member expansion — see file header.)
_TPL_CYCLES=(level1_cycle level2_cycle level3_cycle)

# level1_cycle: members=[level2_cycle], exit_when=level2_cycle/verdict/eq/pass
_TPL_CYCLE_STAGES_level1_cycle="level2_cycle"
_TPL_CYCLE_MAX_level1_cycle=2
_TPL_CYCLE_ON_MAX_level1_cycle="continue"
_TPL_CYCLE_UNTIL_STAGE_level1_cycle="level2_cycle"
_TPL_CYCLE_UNTIL_FIELD_level1_cycle="verdict"
_TPL_CYCLE_UNTIL_OP_level1_cycle="eq"
_TPL_CYCLE_UNTIL_VALUE_level1_cycle="pass"
_TPL_CYCLE_PLATEAU_W_level1_cycle=""
_TPL_CYCLE_DIVERGENCE_W_level1_cycle=""
_TPL_STAGE_TYPE_level1_cycle="cycle"

# level2_cycle: members=[level3_cycle]
_TPL_CYCLE_STAGES_level2_cycle="level3_cycle"
_TPL_CYCLE_MAX_level2_cycle=2
_TPL_CYCLE_ON_MAX_level2_cycle="continue"
_TPL_CYCLE_UNTIL_STAGE_level2_cycle="level3_cycle"
_TPL_CYCLE_UNTIL_FIELD_level2_cycle="verdict"
_TPL_CYCLE_UNTIL_OP_level2_cycle="eq"
_TPL_CYCLE_UNTIL_VALUE_level2_cycle="pass"
_TPL_CYCLE_PLATEAU_W_level2_cycle=""
_TPL_CYCLE_DIVERGENCE_W_level2_cycle=""
_TPL_STAGE_TYPE_level2_cycle="cycle"

# level3_cycle: members=[build, test, test_assessment]
_TPL_CYCLE_STAGES_level3_cycle="build,test,test_assessment"
_TPL_CYCLE_MAX_level3_cycle=2
_TPL_CYCLE_ON_MAX_level3_cycle="continue"
_TPL_CYCLE_UNTIL_STAGE_level3_cycle="test_assessment"
_TPL_CYCLE_UNTIL_FIELD_level3_cycle="verdict"
_TPL_CYCLE_UNTIL_OP_level3_cycle="eq"
_TPL_CYCLE_UNTIL_VALUE_level3_cycle="pass"
_TPL_CYCLE_PLATEAU_W_level3_cycle=""
_TPL_CYCLE_DIVERGENCE_W_level3_cycle=""
_TPL_STAGE_TYPE_level3_cycle="cycle"

# Leaf member types
_TPL_STAGE_TYPE_build="leaf"
_TPL_STAGE_TYPE_test="leaf"
_TPL_STAGE_TYPE_test_assessment="leaf"

# Feedback maps — empty strings so _cycle_apply_feedback no-ops cleanly.
_TPL_CYCLE_FEEDBACK_level1_cycle=""
_TPL_CYCLE_FEEDBACK_level2_cycle=""
_TPL_CYCLE_FEEDBACK_level3_cycle=""

# Mock dispatch: record (iter, stage, label) so we can assert label format.
# Leaves return pass; the orchestrator's nested-cycle branch maps inner-cycle
# rc=0 → verdict=pass on the outer's behalf, so every cycle converges on iter 1.
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    printf 'iter=%s stage=%s label=%s\n' "$iter" "$stage" \
        "${ZBUILD_STAGE_IO_SEQ_LABEL:-MISSING}" >> "$LABEL_LOG"
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

# Simulate the runner publishing level1_cycle's pipeline cardinal as the prefix.
# (In the real runner, this happens at the cycle dispatch unit boundary —
# runner.sh exports ZBUILD_SEQ_PREFIX="$_runner_cardinal" before invoking
# cycle_orchestrator_run.)
export ZBUILD_SEQ_PREFIX=3

set +e
cycle_orchestrator_run "level1_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?
set -e
assert_eq "T1: deep nested cycle converges rc=0" "0" "$rc"

unset ZBUILD_SEQ_PREFIX

expect_label() {
    local iter="$1" stage="$2" expected="$3"
    local actual
    actual="$(grep "^iter=$iter stage=$stage " "$LABEL_LOG" | tail -1 | sed -n 's/.*label=\(.*\)$/\1/p')"
    assert_eq "iter=$iter stage=$stage label=$expected" "$expected" "$actual"
}

# 7-segment labels at the deepest leaves. Prefix breakdown:
#   level1_cycle (prefix=3) iter 1, pos 1 → level2_cycle gets prefix "3.1.1"
#   level2_cycle (prefix=3.1.1) iter 1, pos 1 → level3_cycle gets "3.1.1.1.1"
#   level3_cycle (prefix=3.1.1.1.1) iter 1 → leaves at "3.1.1.1.1.1.<pos>"
expect_label 1 build           "3.1.1.1.1.1.1"
expect_label 1 test            "3.1.1.1.1.1.2"
expect_label 1 test_assessment "3.1.1.1.1.1.3"

# Segment-count check — depth-independence proof.
build_label="$(grep '^iter=1 stage=build ' "$LABEL_LOG" | tail -1 | sed -n 's/.*label=\(.*\)$/\1/p')"
seg_count="$(awk -F. '{print NF}' <<< "$build_label")"
assert_eq "T2: leaf labels at 3-level nest have 7 segments" "7" "$seg_count"

# T3: prefix did not leak out of the top-level orchestrator call.
assert_eq "T3: ZBUILD_SEQ_PREFIX not set after top-level cycle returns" \
    "" "${ZBUILD_SEQ_PREFIX:-}"

print_test_results
cleanup_test_env
