#!/usr/bin/env bash
# Integration: Wave 19-E (#737) — cycle with BOTH exit_when AND abort_when
# converges cleanly when exit_when matches and abort_when does NOT.
#
# Bug: dogfood 20260607140638-60666 (issue 12) — pipeline reported
# pipeline.abort despite review.verdict=approve. Wave 19-D-1 instrumentation
# pinpointed it: _cycle_check_abort_when returns 1 when its predicate does
# not match (the GOOD case — verdict=approve, not block). At
# cycle-orchestrator.sh:1186 the call is bare under reactivated set -e,
# so bash errexit kills cycle_orchestrator_run before reaching the
# cycle.iteration.complete and cycle.complete emits.
#
# Compare: the exit_when call at lines 1170-1173 uses a set +e/set -e
# dance. The abort_when path was missing the same guard — 5-line copy-paste
# oversight from Wave 17-B (ADR-027, #703). Synthetic tests didn't repro
# because none defined abort_when in their templates; only standard.yaml's
# review_cycle has BOTH exit_when AND abort_when.
#
# This is the failing-test-first TDD regression lock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle abort_when non-match converges (Wave 19-E #737)"
setup_test_env "cycle-abort-when-no-match-converges"

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

# Standard.yaml-shape template — single cycle with BOTH exit_when AND
# abort_when defined. Exit_when looks for review=approve; abort_when looks
# for review=block. Mock dispatch returns review=approve. The cycle MUST
# converge via exit_when even though abort_when is defined-but-not-matching.
TPL="$TEST_TEMP_DIR/abort-when-defined.yaml"
cat > "$TPL" <<'EOF'
id: abort_when_defined
name: Cycle with abort_when defined but not matching
defaults:
  strategy: fanout

flow:
  - the_cycle

the_cycle:
  type: cycle
  flow:
    - review
  exit_when:
    stage: review
    field: verdict
    op: eq
    value: approve
  abort_when:
    stage: review
    field: verdict
    op: eq
    value: block
  max_iterations: 2
  on_max: continue

review:
  roles: [reviewer]
EOF

# Mock dispatch — review returns approve (which exit_when matches; abort_when
# does NOT match). On caller-restored set -e, the bare abort_when check
# returns 1 (no match) and crashes the orchestrator pre-fix.
cycle_dispatch_stage() {
    local stage="$1"
    _CYCLE_DISPATCH_VERDICT="pass"        # classified
    _CYCLE_DISPATCH_VERDICT_RAW="approve" # raw — what abort_when/exit_when compare
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$TPL" || assert_fail "template load"

# Exercise the exact errexit context the runner uses. The orchestrator
# runs with set +e internally but the caller (runner) typically has set -e
# active. Set -e here to mirror that, then call.
# Mirror runner.sh's set -e context. The orchestrator's set +e at line 996
# is supposed to insulate the function from the caller's errexit, but the
# inner set +e/set -e dance at lines 1170-1173 RE-arms set -e if the caller
# had it on. That re-armed errexit then trips on the bare abort_when call
# at line 1186 when the predicate returns 1 (the GOOD case — no match).
# Use `|| rc=$?` so the test itself doesn't crash on the orchestrator's
# errexit-driven exit; that pattern matches how runner.sh calls into the
# orchestrator.
set -e
rc=0
cycle_orchestrator_run "the_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE" || rc=$?

print_test_section "outer cycle converges via exit_when when abort_when is defined-but-not-matching"

# T1: cycle returns rc=0 (converged). PRE-FIX, the bare abort_when call
# under set -e crashes the function before _CYCLE_LAST_TERMINATED_REASON
# is set; observed symptom: pipeline.abort fires from EXIT trap.
assert_eq "T1: cycle_orchestrator_run returns rc=0 (exit_when match=true)" "0" "$rc"

# T2: cycle.iteration.complete fired. The bug skips this emit when abort_when
# crashes the orchestrator.
iter_complete=$(jq -c 'select(.type=="cycle.iteration.complete" and .data.cycle_id=="the_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T2: cycle.iteration.complete fired (the bug skips this)" "1" "$iter_complete"

# T3: cycle.complete fired with reason=converged.
cycle_complete=$(jq -c 'select(.type=="cycle.complete" and .data.cycle_id=="the_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T3: cycle.complete fired" "1" "$cycle_complete"

cycle_reason=$(jq -r 'select(.type=="cycle.complete" and .data.cycle_id=="the_cycle") | .data.reason' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "T4: cycle.complete reason=converged (NOT aborted)" "converged" "$cycle_reason"

# T5: Wave 19-C-1 predicate event for abort_when fired (proves the function
# RAN — it emitted its event then returned 1).
abort_pred=$(jq -c 'select(.type=="cycle.predicate.evaluated" and .data.kind=="abort_when" and .data.cycle_id=="the_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T5: cycle.predicate.evaluated kind=abort_when fired (predicate function ran)" "1" "$abort_pred"

abort_match=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="abort_when") | .data.match' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "T6: abort_when match=false (verdict=approve, not block)" "false" "$abort_match"

# T7: terminated_reason global reflects converged.
assert_eq "T7: _CYCLE_LAST_TERMINATED_REASON=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"

# T8: exit_when predicate also fired and matched.
exit_pred_match=$(jq -r 'select(.type=="cycle.predicate.evaluated" and .data.kind=="exit_when") | .data.match' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "T8: exit_when match=true (predicate evaluated before abort_when crash)" "true" "$exit_pred_match"

print_test_section "nested-cycle production scenario (mirror dogfood 20260607140638-60666)"

: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# This shape mirrors standard.yaml: outer review_cycle = [build_test_cycle, review]
# with BOTH exit_when AND abort_when. Inner build_test_cycle converges, then
# review approves. Outer should converge via exit_when on review.verdict=approve.
TPL_NESTED="$TEST_TEMP_DIR/nested-prod.yaml"
cat > "$TPL_NESTED" <<'EOF'
id: nested_prod
name: Nested cycle with abort_when (production shape)
defaults:
  strategy: fanout

flow:
  - review_cycle

review_cycle:
  type: cycle
  flow:
    - build_test_cycle
    - review
  exit_when:
    stage: review
    field: verdict
    op: eq
    value: approve
  abort_when:
    stage: review
    field: verdict
    op: eq
    value: block
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

cycle_dispatch_stage() {
    local stage="$1"
    case "$stage" in
        build|test)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            ;;
        review)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="approve"
            ;;
    esac
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$TPL_NESTED" || assert_fail "nested template load"

set -e
rc=0
cycle_orchestrator_run "review_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE" || rc=$?

# T11: nested-outer cycle returns rc=0.
assert_eq "T11: nested review_cycle returns rc=0" "0" "$rc"

# T12: outer review_cycle's iteration.complete fired (the dogfood-missing event).
nested_iter_complete=$(jq -c 'select(.type=="cycle.iteration.complete" and .data.cycle_id=="review_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T12: nested review_cycle's cycle.iteration.complete fired (dogfood-missing event)" "1" "$nested_iter_complete"

# T13: outer review_cycle's cycle.complete fired with reason=converged.
nested_complete=$(jq -r 'select(.type=="cycle.complete" and .data.cycle_id=="review_cycle") | .data.reason' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "T13: nested review_cycle cycle.complete reason=converged" "converged" "$nested_complete"

# T14: outer's abort_when predicate fired (proves _cycle_check_abort_when ran).
nested_abort_pred=$(jq -c 'select(.type=="cycle.predicate.evaluated" and .data.cycle_id=="review_cycle" and .data.kind=="abort_when")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T14: outer's abort_when predicate event fired" "1" "$nested_abort_pred"

print_test_section "regression guard: cycle without abort_when (unchanged path) still works"

: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

TPL2="$TEST_TEMP_DIR/no-abort-when.yaml"
cat > "$TPL2" <<'EOF'
id: no_abort_when
name: Cycle without abort_when (regression guard)
defaults:
  strategy: fanout

flow:
  - the_cycle

the_cycle:
  type: cycle
  flow:
    - review
  exit_when:
    stage: review
    field: verdict
    op: eq
    value: approve
  max_iterations: 2
  on_max: continue

review:
  roles: [reviewer]
EOF

_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$TPL2" || assert_fail "no-abort-when template load"

# Mirror runner.sh's set -e context. The orchestrator's set +e at line 996
# is supposed to insulate the function from the caller's errexit, but the
# inner set +e/set -e dance at lines 1170-1173 RE-arms set -e if the caller
# had it on. That re-armed errexit then trips on the bare abort_when call
# at line 1186 when the predicate returns 1 (the GOOD case — no match).
# Use `|| rc=$?` so the test itself doesn't crash on the orchestrator's
# errexit-driven exit; that pattern matches how runner.sh calls into the
# orchestrator.
set -e
rc=0
cycle_orchestrator_run "the_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE" || rc=$?

assert_eq "T9: regression guard — no-abort_when cycle converges rc=0" "0" "$rc"

reg_cycle_complete=$(jq -c 'select(.type=="cycle.complete" and .data.cycle_id=="the_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T10: regression guard — cycle.complete emitted" "1" "$reg_cycle_complete"

print_test_results
cleanup_test_env
exit $((FAIL > 0))
