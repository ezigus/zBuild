#!/usr/bin/env bash
# Integration: Wave 19-C-2 (#726) — outer-cycle iter-complete + cycle.complete
# emit reliably when a leaf member converges AFTER an inner cycle returned.
#
# Bug: dogfood 20260605080106-63324 ran cleanly (review verdict=approve,
# cycle-build_review_cycle-history.jsonl row written with status=complete) but
# the outer cycle's `cycle.iteration.complete` and `cycle.complete` events
# never emitted. The runner's EXIT trap fired `pipeline.abort` instead of
# `pipeline.end status=success`.
#
# Wave 19-A (#720) fixed the verdict-channel feed into the predicate. This
# test exercises the missing seam: nested-cycle dispatch followed by a leaf
# that produces the outer's converge verdict. We assert ALL three events:
#   - `cycle.iteration.complete cycle_id=outer`
#   - `cycle.complete cycle_id=outer reason=converged`
#   - `cycle.predicate.evaluated cycle_id=outer kind=exit_when match=true`
#     (Wave 19-C-1's instrumentation; precondition for diagnosing this bug)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "outer cycle converges via leaf-after-inner-cycle (Wave 19-C-2 #726)"
setup_test_env "cycle-nested-outer-converges"

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

# Mirrors standard.yaml build_review_cycle shape: outer cycle [inner_cycle, leaf]
# where the outer's exit_when matches on the leaf's raw verdict AFTER the
# inner cycle has run and converged. Reproduces the exact production scenario
# from dogfood 20260605080106-63324.
TPL="$TEST_TEMP_DIR/nested-outer.yaml"
cat > "$TPL" <<'EOF'
id: nested_outer
name: Nested Outer Convergence Test
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
    value: pass
  max_iterations: 3
  on_max: continue

build:
  roles: [builder]

test:
  roles: [tester]

review:
  roles: [reviewer]
EOF

# Mock dispatch hook — sets both classified AND raw channels for each stage
# the way the real runner's cycle_dispatch_stage does (runner.sh:1109-1152).
# Critical for this test: inner-cycle members (build, test) DO set RAW; this
# is the bleed-through scenario we're hardening against. The outer's review
# member then sets a DIFFERENT RAW ("approve") and the outer's predicate
# must see that, not the inner's stale value.
cycle_dispatch_stage() {
    local stage="$1"
    case "$stage" in
        build)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            ;;
        test)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            ;;
        review)
            _CYCLE_DISPATCH_VERDICT="pass"        # classifier collapses approve→pass
            _CYCLE_DISPATCH_VERDICT_RAW="approve" # raw channel preserves operator-facing verdict
            ;;
        *)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            ;;
    esac
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=()
_TPL_CYCLES=()

set +e
load_template "$TPL"; rc=$?
set -e
assert_eq "T1: template loads rc=0" "0" "$rc"

set +e
cycle_orchestrator_run "build_review_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?
set -e

print_test_section "outer cycle converges + emits all expected events"

# T2: outer cycle returns rc=0 (converged via exit_when on iter 1).
assert_eq "T2: build_review_cycle rc=0 (converged on review.verdict==approve)" "0" "$rc"

# T3: cycle.iteration.complete fired for the OUTER cycle.
# The bug: this never emitted in production despite history file being written.
outer_iter_count=$(jq -c 'select(.type=="cycle.iteration.complete" and .data.cycle_id=="build_review_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T3: cycle.iteration.complete fired for build_review_cycle (the gap dogfood exposed)" "1" "$outer_iter_count"

# T4: cycle.complete reason=converged fired for the OUTER cycle.
outer_complete=$(jq -c 'select(.type=="cycle.complete" and .data.cycle_id=="build_review_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T4: cycle.complete fired for build_review_cycle" "1" "$outer_complete"

outer_reason=$(jq -r 'select(.type=="cycle.complete" and .data.cycle_id=="build_review_cycle") | .data.reason' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "T5: cycle.complete reason=converged (not aborted/max_iterations)" "converged" "$outer_reason"

# T6: inner cycle ALSO emitted both events (was working pre-fix; regression
# guard so the fix doesn't accidentally break the inner-cycle path).
inner_iter_count=$(jq -c 'select(.type=="cycle.iteration.complete" and .data.cycle_id=="build_test_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T6: cycle.iteration.complete fired for build_test_cycle (inner, regression guard)" "1" "$inner_iter_count"

inner_complete=$(jq -c 'select(.type=="cycle.complete" and .data.cycle_id=="build_test_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T7: cycle.complete fired for build_test_cycle (inner, regression guard)" "1" "$inner_complete"

print_test_section "19-C-1 instrumentation: predicate-event diagnostic"

# T8: Wave 19-C-1's cycle.predicate.evaluated event fires for the OUTER
# cycle's exit_when check and match=true. This diagnoses H1 vs H2 vs H3
# from the original plan — if this event is missing entirely, the predicate
# function was never reached (H2). If actual≠approve, verdict accumulation
# is broken (H1/H3). If match=true and actual=approve, the bug is downstream.
outer_predicate=$(jq -c 'select(.type=="cycle.predicate.evaluated" and .data.cycle_id=="build_review_cycle" and .data.kind=="exit_when")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T8: cycle.predicate.evaluated fires for build_review_cycle exit_when (19-C-1 instrumentation)" "1" "$outer_predicate"

outer_predicate_match=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.cycle_id=="build_review_cycle" and .data.kind=="exit_when") | .data.match' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "T9: predicate match=true (verdict_raw=approve reached the outer predicate)" "true" "$outer_predicate_match"

outer_predicate_actual=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.cycle_id=="build_review_cycle" and .data.kind=="exit_when") | .data.actual' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "T10: predicate actual=approve (RAW verdict propagated, not classified)" "approve" "$outer_predicate_actual"

print_test_section "terminated_reason and iteration count"

assert_eq "T11: _CYCLE_LAST_TERMINATED_REASON=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"
assert_eq "T12: _CYCLE_LAST_ITERATIONS=1 (converged on first iter)" "1" "${_CYCLE_LAST_ITERATIONS:-0}"

print_test_results
exit $((FAIL > 0))
