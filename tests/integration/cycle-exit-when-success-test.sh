#!/usr/bin/env bash
# Integration: Wave 19-A (#717) regression lock.
#
# Bug: dogfood 20260605055348-2232 ran cleanly (282 tests pass, review verdict
# approve) but pipeline reported status=aborted. The review_cycle's
# `exit_when: review.verdict == approve` should have fired and ended the
# pipeline with status=complete, but the orchestrator never emitted
# cycle.iteration.complete / cycle.complete for review_cycle — pipeline.abort
# (EXIT trap fallback) fired instead.
#
# Replicates the exact review_cycle shape (outer cycle whose flow is
# [inner_cycle, review_leaf], exit_when on review_leaf.verdict==approve)
# with a stub dispatch that simulates: inner cycle converges, then review
# returns verdict=approve. Asserts the outer cycle converges via exit_when
# (rc=0) and emits cycle.iteration.complete + cycle.complete for the OUTER
# cycle (not just the inner).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle exit_when on leaf-after-inner-cycle (Wave 19-A #717)"
setup_test_env "cycle-exit-when-success"

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

# Template mirrors config/templates/standard.yaml review_cycle shape:
# outer cycle [inner_cycle, review_leaf]; inner cycle is [build, test].
TPL="$TEST_TEMP_DIR/exit-when.yaml"
cat > "$TPL" <<'EOF'
id: exit_when_test
name: Exit When Success Test
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

# Stub dispatch that mirrors runner.sh's cycle_dispatch_stage POST-FIX
# behavior: store the RAW verdict for cycle predicate evaluation. Pre-fix
# (the bug), the runner stored the CLASSIFIED verdict (approve→pass), which
# made review_cycle's exit_when on review.verdict==approve never match.
#
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    case "$stage" in
        build)  _CYCLE_DISPATCH_VERDICT="pass" ;;
        test)   _CYCLE_DISPATCH_VERDICT="pass" ;;
        review) _CYCLE_DISPATCH_VERDICT="approve" ;;
        *)      _CYCLE_DISPATCH_VERDICT="pass" ;;
    esac
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

# Pin: regression-lock verdict_classify still collapses approve→pass. This
# was the silent shadow that hid the bug — the runner USED to feed the
# orchestrator the classified value. If a future refactor changes
# verdict_classify so approve no longer maps to pass, this assertion goes
# loud and we can revisit whether the dispatch path still needs the raw
# read or could rely on the classifier preserving the value.
assert_eq "T0: verdict_classify(approve)=pass (regression-lock of the shadow that hid #717)" "pass" "$(verdict_classify approve)"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=()
_TPL_CYCLES=()

set +e
load_template "$TPL"; rc=$?
set -e
assert_eq "T1: template loads rc=0" "0" "$rc"

set +e
cycle_orchestrator_run "review_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?
set -e

# T2: outer cycle rc=0 (converged via exit_when).
assert_eq "T2: review_cycle rc=0 (converged on review.verdict==approve)" "0" "$rc"

# T3: cycle.iteration.complete fired for OUTER cycle (the bug — orchestrator
# never reached this emit point for review_cycle in the dogfood).
outer_iter_count=$(grep -c '"cycle.iteration.complete".*"cycle_id":"review_cycle"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_eq "T3: cycle.iteration.complete fired for review_cycle (the bug — missing in dogfood)" "1" "$outer_iter_count"

# T4: cycle.complete reason=converged fired for OUTER cycle.
outer_complete=$(jq -c 'select(.type=="cycle.complete" and .data.cycle_id=="review_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T4: cycle.complete fired for review_cycle" "1" "$outer_complete"

# T5: terminated_reason is `converged` (NOT `aborted` / `max_iterations`).
assert_eq "T5: _CYCLE_LAST_TERMINATED_REASON=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"

# T6: dogfood symmetry — exactly one outer iter ran (converged on iter 1).
assert_eq "T6: _CYCLE_LAST_ITERATIONS=1 (converged on first iter, matches dogfood pattern)" "1" "${_CYCLE_LAST_ITERATIONS:-0}"

# T7: runner_read_stage_verdict_raw returns the raw verdict from review.json
# (the fix's seam — without this, the orchestrator can't tell approve from
# pass).
REVIEW_FIXTURE="$ZBUILD_STATE_DIR/artifacts/review.json"
mkdir -p "$(dirname "$REVIEW_FIXTURE")"
cat > "$REVIEW_FIXTURE" <<'EOF'
{
  "schema_version": 1,
  "verdict": "approve",
  "confidence": 0.97,
  "issues": [],
  "summary": "test fixture"
}
EOF
REVIEW_MANIFEST="$REPO_ROOT/plugins/agent/review/manifest.yaml"
RAW=$(runner_read_stage_verdict_raw "$ZBUILD_STATE_DIR" "$REVIEW_MANIFEST" "review" 0)
assert_eq "T7: runner_read_stage_verdict_raw returns raw 'approve' (not classified 'pass')" "approve" "$RAW"

# T8: runner_read_stage_verdict (classified) still returns "pass" — proves
# the original classifier is untouched (no regression on the indicator path).
CLS=$(runner_read_stage_verdict "$ZBUILD_STATE_DIR" "$REVIEW_MANIFEST" "review" 0)
assert_eq "T8: runner_read_stage_verdict (classified) unchanged: approve→pass" "pass" "$CLS"

print_test_results
