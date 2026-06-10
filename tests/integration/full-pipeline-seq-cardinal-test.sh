#!/usr/bin/env bash
# Integration test: end-to-end pipeline (intake → plan → build → test →
# test_assessment → review) populates ZBUILD_STAGE_IO_SEQ_LABEL with the
# correct CARDINAL position per linear stage (#682, Wave 15-D).
#
# Mock plugins log the value of $ZBUILD_STAGE_IO_SEQ_LABEL they observe.
# Expected linear cardinal numbering (legacy path, cycles disabled):
#   intake=1, plan=2, build=3, test=4, test_assessment=5, review=6
# When cycles are enabled and the build/test cycle occupies ONE cardinal slot,
# linear stages after the cycle continue from cycle_cardinal+1 — covered by
# the cycle-aware tests; this test pins the legacy linear path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "full pipeline cardinal seq labels (#682)"
setup_test_env "full-pipeline-seq-cardinal"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
LABEL_LOG="$TEST_TEMP_DIR/labels.log"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
# Force LEGACY linear loop so cardinal counting comes from active_stages[].
export ZBUILD_CYCLES_ENABLED=0
export ZBUILD_SEQ_LABEL_LOG="$LABEL_LOG"
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"
: > "$LABEL_LOG"

# Custom plugin factory: each plugin logs the observed seq label and stage name.
_make_logging_plugin() {
    local id="$1"
    local dir="$PLUGINS_ROOT/agent/$id"
    mkdir -p "$dir"
    local fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: agent
version: 0.0.1
hooks:
  run: $fn
requires:
  core:
    - redaction
EOF
    cat > "$dir/plugin.sh" <<EOF
${fn}() {
    printf 'stage=%s label=%s\n' "$id" "\${ZBUILD_STAGE_IO_SEQ_LABEL:-MISSING}" \
        >> "\${ZBUILD_SEQ_LABEL_LOG:-/dev/null}"
    return 0
}
EOF
}

for s in intake plan impact design build test test_assessment review; do
    _make_logging_plugin "$s"
done

rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
set +e; bash "$RUNNER" --issue 83 >/dev/null 2>&1; rc=$?; set -e
assert_eq "pipeline exits 0" "0" "$rc"

expect_label() {
    local stage="$1" expected="$2"
    local actual
    actual="$(grep "^stage=$stage " "$LABEL_LOG" | head -1 | sed -n 's/.*label=\(.*\)$/\1/p')"
    assert_eq "stage=$stage label=$expected" "$expected" "$actual"
}

# Cardinal numbering — one per linear stage in order.
# #746: impact added between plan and build (plan_impact_cycle flattened).
expect_label intake          "1"
expect_label plan            "2"
expect_label impact          "3"
expect_label design          "4"
expect_label build           "5"
expect_label test            "6"
expect_label test_assessment "7"
expect_label review          "8"

print_test_results
cleanup_test_env
