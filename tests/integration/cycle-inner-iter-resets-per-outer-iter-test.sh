#!/usr/bin/env bash
# Integration: Wave 19-D-2 (#732) — inner cycle iter counter and history
# file reset on each outer iteration.
#
# The user's diagnosis (post-dogfood 20260605140602-80831): "the outer
# loop when it resets to the next iteration should reset the inner loop
# count". The orchestrator's recursive design at cycle_orchestrator_run
# lines 1003-1018 ALREADY does this naturally:
#   - line 1003: _CYCLE_TRAP_ITER=0
#   - line 1005: _CYCLE_LAST_ITERATIONS=0
#   - line 1018: : > "$history_file"   (truncates inner's history)
#   - line 1033: for (( iter=1; iter <= _CYCLE_MAX_ITER; iter++ ))
#
# But no test proves the reset happens end-to-end across outer iters. A
# future refactor of the recursive call could break it silently. This
# test is the regression lock.
#
# Scenario:
#   outer max=2 / inner max=2
#   inner ALWAYS fails (build verdict=fail, hits max_iter, returns rc=1)
#   outer iter 1: inner runs → max_iter, then review verdict=request_changes
#                 → outer doesn't converge, no abort, continues to iter 2
#   outer iter 2: inner runs AGAIN — must start at iter=1, history truncated
#                 then review verdict=approve → outer converges
#
# Assertions:
#   - inner cycle.start fires TWICE (once per outer iter)
#   - both inner cycle.start events have iter=1 (fresh start, not 4)
#   - inner history file contains exactly 2 rows (iters 1 and 2 — from
#     outer iter 2's inner run), proving truncation between outer iters
#     (not 4 rows accumulated across both outer iters)
#   - outer cycle.iteration.complete fires twice
#   - outer cycle.complete reason=converged
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "inner cycle iter+history reset per outer iter (Wave 19-D-2 #732)"
setup_test_env "cycle-inner-iter-resets-per-outer"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
INNER_HISTORY="$ZBUILD_STATE_DIR/cycle-build_test_cycle-history.jsonl"
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

TPL="$TEST_TEMP_DIR/two-level.yaml"
cat > "$TPL" <<'EOF'
id: two_level_reset
name: Inner Resets per Outer Iter Test
defaults:
  strategy: fanout

flow:
  - build_review_cycle

build_review_cycle:
  type: cycle
  flow:
    - build_test_cycle
    - review
  exit_when:
    stage: review
    field: verdict
    op: eq
    value: approve
  max_iterations: 2
  on_max: continue

build_test_cycle:
  type: cycle
  flow:
    - build
    - test
  exit_when:
    stage: test
    field: verdict
    op: eq
    value: approve
  max_iterations: 2
  on_max: continue

build:
  roles: [builder]

test:
  roles: [tester]

review:
  roles: [reviewer]
EOF

# Inner never converges but its TESTS PASS: build/test emit verdict=pass while the
# inner exit_when requires test.verdict==approve (a value `test` never emits), so
# the inner exhausts max_iterations UNCONVERGED-BUT-PASSING → #1208 rc=2 (soft,
# non-halting) — NOT rc=8 (a failing-test inner would hard-halt the outer, #1208).
# This keeps the inner non-fatal so the outer re-dispatches it across outer iters,
# exercising the iter+history reset (the actual regression under test) without the
# #944 anti-pattern of advisory-review-rescuing failing tests.
# Outer's review flips: outer iter 1 → request_changes (forces outer iter 2),
# outer iter 2 → approve (forces convergence).
_OUTER_ITER_OBSERVED=0
cycle_dispatch_stage() {
    local stage="$1"
    case "$stage" in
        build|test)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            ;;
        review)
            _OUTER_ITER_OBSERVED=$(( _OUTER_ITER_OBSERVED + 1 ))
            if [[ $_OUTER_ITER_OBSERVED -eq 1 ]]; then
                _CYCLE_DISPATCH_VERDICT="fail"
                _CYCLE_DISPATCH_VERDICT_RAW="request_changes"
            else
                _CYCLE_DISPATCH_VERDICT="pass"
                _CYCLE_DISPATCH_VERDICT_RAW="approve"
            fi
            ;;
    esac
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$TPL" || assert_fail "template load"

set +e; cycle_orchestrator_run "build_review_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e

print_test_section "outer iter 2 entered and converges"

assert_eq "T1: outer cycle converges rc=0 (review approve on iter 2)" "0" "$rc"
assert_eq "T2: review was called twice (one per outer iter)" "2" "$_OUTER_ITER_OBSERVED"

print_test_section "inner cycle resets across outer iters"

# T3: inner cycle.start fires exactly twice (once per outer iter).
inner_start_count=$(jq -c 'select(.type=="cycle.start" and .data.cycle_id=="build_test_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T3: inner cycle.start emitted twice (one per outer iter)" "2" "$inner_start_count"

# T4: BOTH inner cycle.start events report iter=1 (fresh, not continuing).
both_at_iter1=$(jq -r 'select(.type=="cycle.start" and .data.cycle_id=="build_test_cycle") | .data.iter' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | sort -u)
assert_eq "T4: both inner cycle.start at iter=1 (RESET, not 4)" "1" "$both_at_iter1"

# T5: inner cycle.complete fires twice (one per outer iter), both max_iterations.
inner_complete_count=$(jq -c 'select(.type=="cycle.complete" and .data.cycle_id=="build_test_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T5: inner cycle.complete emitted twice" "2" "$inner_complete_count"

inner_reasons=$(jq -r 'select(.type=="cycle.complete" and .data.cycle_id=="build_test_cycle") | .data.reason' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | sort -u)
assert_eq "T6: both inner runs terminated reason=max_iterations" "max_iterations" "$inner_reasons"

# T7: inner cycle.iteration.complete events — should be 4 total (2 iters × 2 outer iters).
inner_iter_complete_count=$(jq -c 'select(.type=="cycle.iteration.complete" and .data.cycle_id=="build_test_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T7: inner cycle.iteration.complete emitted 4 times (2 iter × 2 outer iter)" "4" "$inner_iter_complete_count"

# T8: each inner pass's iteration.complete events go iter=1, iter=2.
inner_iters_observed=$(jq -r 'select(.type=="cycle.iteration.complete" and .data.cycle_id=="build_test_cycle") | .data.iter' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | sort | uniq -c | sed 's/^[[:space:]]*//')
assert_eq "T8: inner iteration counts: 2 of iter=1, 2 of iter=2 (proves reset)" "$(printf '2 1\n2 2')" "$inner_iters_observed"

print_test_section "inner history file truncated on outer iter 2"

# T9: inner history file ends with the LAST outer iter's iter rows only.
# After outer iter 2 completes, inner history should contain exactly 2 rows
# (from outer iter 2's inner run), NOT 4 rows accumulated across outer iters.
history_row_count=$(wc -l "$INNER_HISTORY" 2>/dev/null | awk '{print $1}' || echo 0)
assert_eq "T9: inner history file contains 2 rows (truncated on outer iter 2 entry)" "2" "$history_row_count"

# T10: the rows in the inner history are iter 1 and iter 2 (NOT iter 3, 4).
history_iters=$( { jq -r '.n' "$INNER_HISTORY" 2>/dev/null || true; } | sort -u | tr '\n' ',' | sed 's/,$//')
assert_eq "T10: inner history rows have iter=1 and iter=2 only (reset on outer iter 2)" "1,2" "$history_iters"

print_test_section "outer cycle emits expected events"

outer_iter_complete=$(jq -c 'select(.type=="cycle.iteration.complete" and .data.cycle_id=="build_review_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T11: outer cycle.iteration.complete emitted twice" "2" "$outer_iter_complete"

outer_complete=$(jq -r 'select(.type=="cycle.complete" and .data.cycle_id=="build_review_cycle") | .data.reason' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "T12: outer cycle.complete reason=converged" "converged" "$outer_complete"

print_test_section "Wave 19-D-1 member.dispatch events span both outer iters"

# Outer iter 1: dispatches build_test_cycle (kind=cycle) + review (kind=leaf). 2 start events.
# Outer iter 2: same. 2 more start events. Total: 4 dispatch.start at the outer cycle.
outer_dispatch_starts=$(jq -c 'select(.type=="cycle.member.dispatch.start" and .data.cycle_id=="build_review_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T13: 4 cycle.member.dispatch.start at outer (2 members × 2 iters)" "4" "$outer_dispatch_starts"

# Each outer iter dispatches inner_cycle then review. So we should see this
# exact ordering at the outer level: build_test_cycle, review, build_test_cycle, review.
outer_dispatch_members=$(jq -r 'select(.type=="cycle.member.dispatch.start" and .data.cycle_id=="build_review_cycle") | .data.member' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
assert_eq "T14: outer member dispatch order is build_test_cycle,review,build_test_cycle,review" "build_test_cycle,review,build_test_cycle,review" "$outer_dispatch_members"

# Inner cycle's dispatch.complete on iter 1 (after inner returns rc=1) records verdict=fail.
inner_member_complete_verdicts=$(jq -r 'select(.type=="cycle.member.dispatch.complete" and .data.cycle_id=="build_review_cycle" and .data.member=="build_test_cycle") | .data.verdict' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | sort -u)
assert_eq "T15: inner_cycle dispatch.complete verdict=fail (max_iter mapping)" "fail" "$inner_member_complete_verdicts"

print_test_results
cleanup_test_env
exit $((FAIL > 0))
