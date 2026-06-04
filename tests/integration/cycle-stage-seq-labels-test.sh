#!/usr/bin/env bash
# Integration test: cycle orchestrator threads <iter>.<position> seq labels to
# the per-stage banner via ZBUILD_STAGE_IO_SEQ_LABEL (#682, Wave 15-D).
#
# Drives cycle_orchestrator_run with a 2-iter, 3-stage cycle. The mock
# cycle_dispatch_stage hook records the value of ZBUILD_STAGE_IO_SEQ_LABEL it
# observes for each (stage, iter) pair. Asserts the sequence:
#   iter 1: build=1.1, test=1.2, test_assessment=1.3
#   iter 2: build=2.1, test=2.2, test_assessment=2.3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle orchestrator hierarchical seq labels (#682)"
setup_test_env "cycle-seq-labels"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
LABEL_LOG="$TEST_TEMP_DIR/labels.log"
: > "$LABEL_LOG"

cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    printf 'iter=%s stage=%s label=%s\n' "$iter" "$stage" \
        "${ZBUILD_STAGE_IO_SEQ_LABEL:-MISSING}" >> "$LABEL_LOG"
    # Force convergence on iter 2 so the loop runs exactly 2 iters.
    if [[ "$stage" == "test_assessment" && "$iter" -ge 2 ]]; then
        _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"
    else
        _CYCLE_DISPATCH_VERDICT="fail"; _CYCLE_DISPATCH_STATUS="failed"
    fi
    return 0
}

# Build an inline cycle template via load_template using a temp file.
TPL="$TEST_TEMP_DIR/seq-label-cycle.yaml"
cat >"$TPL" <<'YAML'
id: seq-label-cycle
name: Seq label test
defaults:
  strategy: fanout
stages:
  - id: build-test
    type: cycle
    stages: [build, test, test_assessment]
    until:
      stage: test_assessment
      field: verdict
      op: eq
      value: pass
    max_iterations: 5
    on_max: continue
stage_definitions:
  build:
    roles: [builder]
  test:
    roles: [tester]
  test_assessment:
    roles: [assessor]
YAML

jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
load_template "$TPL"

set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e

assert_eq "orchestrator converged" "0" "$rc"

# Verify each (iter,stage) → label binding
expect_label() {
    local iter="$1" stage="$2" expected="$3"
    local actual
    actual="$(grep "^iter=$iter stage=$stage " "$LABEL_LOG" | head -1 | sed -n 's/.*label=\(.*\)$/\1/p')"
    assert_eq "iter=$iter stage=$stage label=$expected" "$expected" "$actual"
}

expect_label 1 build           "1.1"
expect_label 1 test            "1.2"
expect_label 1 test_assessment "1.3"
expect_label 2 build           "2.1"
expect_label 2 test            "2.2"
expect_label 2 test_assessment "2.3"

print_test_results
cleanup_test_env
