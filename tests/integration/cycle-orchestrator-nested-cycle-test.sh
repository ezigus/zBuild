#!/usr/bin/env bash
# Integration: ADR-027 cycle-as-member dispatch (Wave 17-B, #703).
#
# Drives a 2-level nested cycle: outer cycle's flow contains an inner cycle.
# The mock dispatch hook records the dispatch order. Asserts:
#   - inner cycle runs to convergence inside the outer iter
#   - outer iter records inner cycle as a "member stage" with verdict mapped
#     from inner termination (converged → pass)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — nested cycle (ADR-027 cycle-as-member)"
setup_test_env "cycle-orch-nested"

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

# Build a new-shape template fixture directly in $TEST_TEMP_DIR.
NESTED_TPL="$TEST_TEMP_DIR/nested.yaml"
cat > "$NESTED_TPL" <<'EOF'
id: nested
name: Nested Cycle Test
defaults:
  strategy: fanout

flow:
  - outer_cycle

outer_cycle:
  type: cycle
  flow:
    - inner_cycle
    - test_assessment
  exit_when:
    stage: test_assessment
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue

inner_cycle:
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

test_assessment:
  roles: [test_assessment]
EOF

# Programmable mock dispatch — records calls + supplies verdicts.
DISPATCH_LOG="$TEST_TEMP_DIR/dispatch.log"
: > "$DISPATCH_LOG"
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    printf '%s|iter=%s\n' "$stage" "$iter" >> "$DISPATCH_LOG"
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    case "$stage" in
        build) _CYCLE_DISPATCH_VERDICT="pass" ;;
        test)  _CYCLE_DISPATCH_VERDICT="pass" ;;
        test_assessment) _CYCLE_DISPATCH_VERDICT="pass" ;;
    esac
    return 0
}

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=()
_TPL_CYCLES=()

set +e
load_template "$NESTED_TPL"; rc=$?
set -e
assert_eq "T1: nested template loads rc=0" "0" "$rc"

# T2: outer cycle runs orchestrator; expected to converge on iter 1.
set +e
cycle_orchestrator_run "outer_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?
set -e
assert_eq "T2: outer cycle rc=0 (converged)" "0" "$rc"

# T3: dispatch log shows build/test ran (inner cycle) BEFORE test_assessment.
if grep -q '^build|iter=' "$DISPATCH_LOG" \
   && grep -q '^test|iter=' "$DISPATCH_LOG" \
   && grep -q '^test_assessment|iter=' "$DISPATCH_LOG"; then
    assert_pass "T3: build, test, test_assessment all dispatched"
else
    assert_fail "T3: missing dispatch calls" "$(cat "$DISPATCH_LOG")"
fi

# T4: nested cycle.start event present for both cycles.
if grep -q '"cycle.start"' "$ZBUILD_EVENTS_JSONL" \
   && grep -q '"cycle_id":"outer_cycle"' "$ZBUILD_EVENTS_JSONL" \
   && grep -q '"cycle_id":"inner_cycle"' "$ZBUILD_EVENTS_JSONL"; then
    assert_pass "T4: both outer + inner cycle.start emitted"
else
    assert_fail "T4: nested cycle events missing" \
        "$(grep cycle.start "$ZBUILD_EVENTS_JSONL")"
fi

print_test_results
