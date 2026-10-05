#!/usr/bin/env bash
# tests/integration/nested-loop-rounds-test.sh — the outer loop goes round when
# an inner loop ends without converging (#2271, ADR-068).
#
# Why: the default flow becomes one outer loop holding the design loop and the
# build loop (Eric, 2026-10-04). An inner loop that uses up its rounds must not
# halt the run while the outer loop has rounds left, and must not let the outer
# round carry on into later members as if nothing happened: build must not run
# on a design its checks still reject. The outer round ends there, the outer
# loop goes round from the top, and each inner loop starts again with a fresh
# counter. When the outer rounds are spent, the run stops.
#
# L1 [guard]  everything passes: one outer round, every member runs once
# L2 [change] the design loop runs out of rounds: build is skipped, the outer
#             loop goes round and design starts again at round 1; when the
#             outer rounds are spent, the outer loop does not report success
# L3 [change] the build loop runs out of rounds with tests failing: the run is
#             not halted at once — the outer loop goes round from design
# L4 [change] design fails in outer round 1 only: round 2 starts design with a
#             fresh counter, and the outer loop then converges
# L5 [change] an outer exit_when with several conditions is read correctly
#             after an inner loop with a single condition has run inside it
# L6 [guard]  a build loop that is blocked (a structural failure) stops the run
#             — the outer loop does not go round to repeat it (written after
#             the fix, with the rate-limit case covered by
#             cycle-rate-limit-aborts-run-test.sh)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the outer loop goes round when an inner loop ends unconverged (#2271)"
setup_test_env "nested-loop-rounds"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

TPL="$TEST_TEMP_DIR/nested.yaml"
cat > "$TPL" <<'EOF'
id: nested-rounds
name: Nested loop rounds
defaults:
  strategy: fanout

flow:
  - outer_loop

outer_loop:
  type: cycle
  flow:
    - design_loop
    - impact
    - build_loop
  exit_when:
    all:
      - { stage: design_loop, field: verdict, op: eq, value: pass }
      - { stage: build_loop, field: verdict, op: eq, value: pass }
  max_iterations: 2
  on_max: halt

design_loop:
  type: cycle
  flow:
    - design
    - design_gate
  exit_when:
    stage: design_gate
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: halt

build_loop:
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

design:
  roles: [designer]
design_gate:
  roles: [design_gate]
impact:
  roles: [impact]
build:
  roles: [builder]
test:
  roles: [tester]
EOF

LOG="$TEST_TEMP_DIR/dispatch.log"
OUTER_ROUND_FILE="$TEST_TEMP_DIR/outer-round"
# The stub: DESIGN_GATE=pass|fail|fail-first-round, TEST=pass|fail.
# shellcheck disable=SC2329  # called by the orchestrator
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    printf '%s|iter=%s\n' "$stage" "$iter" >> "$LOG"
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_REPORT="{}"
    case "$stage" in
        design)
            # Count outer rounds by design's own round-1 dispatches.
            [[ "$iter" == "1" ]] && printf 'x' >> "$OUTER_ROUND_FILE" ;;
        design_gate)
            case "${DESIGN_GATE:-pass}" in
                fail) _CYCLE_DISPATCH_VERDICT="fail" ;;
                fail-first-round)
                    [[ "$(wc -c < "$OUTER_ROUND_FILE" | tr -d ' ')" == "1" ]] && _CYCLE_DISPATCH_VERDICT="fail" ;;
            esac ;;
        build)
            [[ "${BUILD:-ok}" == "blocked" ]] && { _CYCLE_DISPATCH_VERDICT="fail"; _CYCLE_DISPATCH_VERDICT_RAW="error"; } ;;
        test)
            if [[ "${TEST:-pass}" == "fail" ]]; then
                _CYCLE_DISPATCH_VERDICT="fail"
                _CYCLE_DISPATCH_REPORT='{"tests":{"total":3,"failed":1}}'
            fi ;;
    esac
    return 0
}

_run() {   # _run → rc of the outer loop; the dispatch log is left in $LOG
    : > "$LOG"; : > "$OUTER_ROUND_FILE"; : > "$ZBUILD_EVENTS_JSONL"
    local sf="$ZBUILD_STATE_DIR/pipeline-state.json"
    rm -f "$sf" "$sf.bak" "$sf.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$sf"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$TPL" >/dev/null 2>&1 || { echo "load_template failed" >&2; return 99; }
    cycle_orchestrator_run outer_loop "$ZBUILD_STATE_DIR" "$sf" >/dev/null 2>&1
}
_count() { grep -c "^$1|iter=$2\$" "$LOG" || true; }

print_test_section "L1/L5: everything passes"
DESIGN_GATE=pass TEST=pass _run; rc=$?
assert_eq "[L1] the outer loop converges" "0" "$rc"
assert_eq "[L1] design runs once" "1" "$(_count design 1)"
assert_eq "[L1] impact runs once" "1" "$(_count impact 1)"
assert_eq "[L5] the outer loop needs only one round" "1" "$(grep -c '^impact|' "$LOG" || true)"

print_test_section "L2: the design loop runs out of rounds"
DESIGN_GATE=fail TEST=pass _run; rc=$?
assert_eq "[L2] design starts again at round 1 in the second outer round" "2" "$(_count design 1)"
assert_eq "[L2] build never runs on a design the checks reject" "0" "$(grep -c '^build|' "$LOG" || true)"
assert_eq "[L2] impact never runs either" "0" "$(grep -c '^impact|' "$LOG" || true)"
if [[ "$rc" -ne 0 ]]; then
    assert_pass "[L2] the outer loop does not report success (rc=$rc)"
else
    assert_fail "[L2] the outer loop does not report success" "rc=0"
fi

print_test_section "L3: the build loop runs out of rounds with tests failing"
DESIGN_GATE=pass TEST=fail _run; rc=$?
assert_eq "[L3] the outer loop goes round: design runs again" "2" "$(_count design 1)"
assert_eq "[L3] the build loop starts again at round 1" "2" "$(_count build 1)"
if [[ "$rc" -ne 0 ]]; then
    assert_pass "[L3] when the outer rounds are spent the run does not succeed (rc=$rc)"
else
    assert_fail "[L3] when the outer rounds are spent the run does not succeed" "rc=0"
fi

print_test_section "L4: design fails in the first outer round only"
DESIGN_GATE=fail-first-round TEST=pass _run; rc=$?
assert_eq "[L4] the outer loop converges in round 2" "0" "$rc"
assert_eq "[L4] design started at round 1 in both outer rounds" "2" "$(_count design 1)"
assert_eq "[L4] build ran once, in round 2" "1" "$(_count build 1)"

print_test_section "L6: a blocked build loop stops the run"
DESIGN_GATE=pass TEST=fail BUILD=blocked _run; rc=$?
assert_eq "[L6] the outer loop does not go round" "1" "$(_count design 1)"
assert_eq "[L6] the run stops as blocked (rc=5), not as a config error" "5" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
