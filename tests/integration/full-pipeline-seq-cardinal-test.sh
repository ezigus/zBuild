#!/usr/bin/env bash
# Integration test: end-to-end pipeline populates ZBUILD_STAGE_IO_SEQ_LABEL with
# the correct CARDINAL position per linear stage (#682, Wave 15-D).
#
# TEMPLATE-AGNOSTIC (#966): this pins the ENGINE's legacy-linear cardinal counter,
# NOT any shipped roster. It drives a MINIMAL test-owned fixture
# (runner-state-dir-minimal.yaml — two leaf stages intake → build) installed as a
# per-repo `.zbuild/templates/` overlay (#1270), so flipping the default template
# or retiring standard.yaml (#979) cannot shatter it. The prior version pinned the
# 14-stage standard roster (intake=1 … pr=14) purely as a vehicle for the counter.
# The cardinal-per-linear-stage behavior is stage-count-independent: two leaf
# stages exercise the same code path (runner.sh _runner_linear_cardinal) as
# fourteen. Cycle/parallel constructs would render hierarchical labels via the
# orchestrators (ZBUILD_SEQ_PREFIX) — a DIFFERENT path this test does not cover;
# it explicitly pins the legacy LINEAR path (ZBUILD_CYCLES_ENABLED=0), as before.
#
# Mock plugins log the value of $ZBUILD_STAGE_IO_SEQ_LABEL they observe.
# Expected linear cardinal numbering (legacy path, cycles disabled):
#   intake=1, build=2
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

# The fixture's two leaf stages (declaration/flow order: intake → build).
for s in intake build; do
    _make_logging_plugin "$s"
done

# #1270: install the minimal fixture as a per-repo `.zbuild/templates/` overlay in
# a temp repo and run the runner with CWD = that repo (the resolver reads the
# overlay from $PWD). Nothing is written into the tracked config/templates/.
OVERLAY_REPO="$(setup_git_temp_repo tpl-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" runner-state-dir-minimal

rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
set +e
( cd "$OVERLAY_REPO" && env \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_STATE_DIR="$STATE_DIR" \
    ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" \
    ZBUILD_EVENTS_JSONL="$EVENTS_JSONL" \
    ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CYCLES_ENABLED=0 \
    ZBUILD_SEQ_LABEL_LOG="$LABEL_LOG" \
    ZBUILD_CONTRACT_VALIDATOR=warn \
    PATH="$PATH" HOME="$HOME" \
    bash "$RUNNER" --template runner-state-dir-minimal --issue 83 ) >/dev/null 2>&1
rc=$?
set -e
assert_eq "pipeline exits 0" "0" "$rc"

expect_label() {
    local stage="$1" expected="$2"
    local actual
    actual="$(grep "^stage=$stage " "$LABEL_LOG" | head -1 | sed -n 's/.*label=\(.*\)$/\1/p')"
    assert_eq "stage=$stage label=$expected" "$expected" "$actual"
}

# Cardinal numbering — one per linear stage in FLOW order (fixture: intake, build).
expect_label intake "1"
expect_label build  "2"

# [SPEC-1] cardinality: exactly the fixture's leaf stages ran, one cardinal each.
label_lines="$(grep -c '^stage=' "$LABEL_LOG" || true)"
assert_eq "[SPEC-1] exactly 2 linear stages recorded a cardinal label" "2" "$label_lines"

# [SPEC-2] sequence: intake's cardinal precedes build's (monotonic, no collision).
first_stage="$(head -1 "$LABEL_LOG" | sed -n 's/^stage=\([^ ]*\).*/\1/p')"
assert_eq "[SPEC-2] first dispatched stage is intake (cardinal 1)" "intake" "$first_stage"

print_test_results
cleanup_test_env
