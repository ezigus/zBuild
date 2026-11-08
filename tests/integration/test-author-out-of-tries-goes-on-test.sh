#!/usr/bin/env bash
# tests/integration/test-author-out-of-tries-goes-on-test.sh — a test-author
# that runs out of tries does not stop the run: the round goes on with the
# tests as they are, and the next round starts from design (#2491, ADR-013,
# ADR-068 §3).
#
# Why: on #1805 run 42439063480 test-author spent its three tries on DSCMBR-1,
# whose Given says the saved state records "in-progress" while the engine
# writes `aborted`. Only design can rewrite the Given, but test-author was
# blocking: the run ended `out_of_tries:build_test_cycle` in round 1, and design
# never got the round that would let it.
#
# T1 [change] the shipped template: test-author out of tries, build still runs
#             in that round
# T2 [change] ...and round 2 starts from design
# T3 [guard]  a design that fails still ends the run (stop_run_on_fail)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a test-author out of tries does not stop the run (#2491)"
setup_test_env "test-author-out-of-tries-goes-on"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

LOG="$TEST_TEMP_DIR/dispatch.log"
# FAILS: "<stage>@<round>" pairs that fail, as a stage out of tries reports it.
# shellcheck disable=SC2329  # called by the orchestrator
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    printf '%s|iter=%s\n' "$stage" "$iter" >> "$LOG"
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_REPORT="{}"
    if [[ " $FAILS " == *" $stage@$iter "* ]]; then
        _CYCLE_DISPATCH_VERDICT="fail"; return 1
    fi
    return 0
}
_run() {
    : > "$LOG"; : > "$ZBUILD_EVENTS_JSONL"
    local sf="$ZBUILD_STATE_DIR/pipeline-state.json"
    rm -f "$sf" "$sf.bak" "$sf.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$sf"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1 || { echo "load_template failed" >&2; return 99; }
    cycle_orchestrator_run build_test_cycle "$ZBUILD_STATE_DIR" "$sf" >/dev/null 2>&1
    RUN_RC=$?
}
_ran() { grep -c "^$1|iter=$2$" "$LOG" || true; }

# ── T1 / T2 ──────────────────────────────────────────────────────────────────
# Given the shipped template, and a test-author that fails round 1 (out of tries)
FAILS="test-author@1" _run
# Then build runs on the tests as they are, and round 2 starts from design
assert_eq "[T1] build runs in the round test-author ran out of tries" "1" "$(_ran build 1)"
assert_eq "[T1] ...and so does the test stage" "1" "$(_ran test 1)"
assert_eq "[T1] no blocking failure is said" "0" "$(grep -c 'cycle.member.blocking_failure' "$ZBUILD_EVENTS_JSONL" || true)"
assert_eq "[T2] round 2 starts from design" "1" "$(_ran design 2)"
assert_eq "[T2] ...and the loop then passes" "0" "$RUN_RC"

# ── T3 ───────────────────────────────────────────────────────────────────────
FAILS="design@1" _run
assert_eq "[T3] a design that fails still ends the run in round 1" "0" "$(_ran design 2)"
assert_eq "[T3] ...failed" "1" "$([[ $RUN_RC -ne 0 ]] && echo 1 || echo 0)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
