#!/usr/bin/env bash
# tests/unit/cycle-history-multi-exit-test.sh — a loop that ends on several
# conditions (exit_when all:/any:) records each one's outcome in its history
# (ADR-047, ADR-021).
#
# Why: the history row read one "until" stage, which only a single-condition
# loop has. Every row of design_verify_cycle (exit_when all: spec-coverage,
# design-gate) read "verdict":"missing","status":"missing" — #1801 run
# 38554963653 and #1944 run 38554967181 — so the file said nothing about
# which gate held the loop.
#
#   H1 [change] each row names every exit condition's stage and its outcome
#   H2 [guard]  the loop still converges once every condition holds
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle history: one outcome per exit condition (ADR-047)"
setup_test_env "cycle-history-multi-exit"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# round 1: gate-a fails; round 2: gate-b fails; round 3: both pass.
cycle_dispatch_stage() {
    local stage="$1" iter="$2" v=pass
    [[ "$stage" == gate-a && "$iter" == 1 ]] && v=fail
    [[ "$stage" == gate-b && "$iter" == 2 ]] && v=fail
    _CYCLE_DISPATCH_VERDICT="$v"
    [[ "$v" == fail ]] && _CYCLE_DISPATCH_STATUS="failed" || _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

TPL="$TEST_TEMP_DIR/tpl.yaml"
cp "$REPO_ROOT/tests/fixtures/templates/cycle-multi-exit-when-all.yaml" "$TPL"
load_template "$TPL"
set +e; cycle_orchestrator_run "build-test-cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
H="$ZBUILD_STATE_DIR/cycle-build-test-cycle-history.jsonl"

print_test_section "H1: each row names every condition's outcome"
assert_eq "[H1] round 1 row" "gate-a=fail gate-b=pass" "$(sed -n 1p "$H" | jq -r .verdict)"
assert_eq "[H1] round 2 row" "gate-a=pass gate-b=fail" "$(sed -n 2p "$H" | jq -r .verdict)"
assert_eq "[H1] no row says missing" "0" "$(grep -c '"missing"' "$H" || true)"

print_test_section "H2: the loop converges"
assert_eq "[H2] the loop converges" "0" "$rc"
assert_eq "[H2] ...in round 3" "3" "$(wc -l < "$H" | tr -d ' ')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
