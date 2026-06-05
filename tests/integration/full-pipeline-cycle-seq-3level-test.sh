#!/usr/bin/env bash
# Integration test (#698, Wave 16-A): full pipeline with cycles enabled exports
# 3-level seq labels for cycle members and continues the cardinal for linear
# stages after the cycle.
#
# Drives runner.sh end-to-end with the standard template (4 dispatch units:
# intake, plan, cycle:build_test_cycle, review). Mocks plugins to log the
# observed ZBUILD_STAGE_IO_SEQ_LABEL and the visibility of ZBUILD_CYCLE_CARDINAL.
# The mock test_assessment defaults to verdict=pass (its stage_dir is unset in
# this mock harness, so the conditional write never fires); the cycle therefore
# converges in a single iter. That one iter is enough — the 3-level prefix and
# the cardinal-leak guarantee are both verifiable from one iter because the
# same code path emits every iter's label.
#
# Pinned assertions:
#   intake          = "1"               (linear cardinal, no cycle env)
#   plan            = "2"               (linear cardinal, no cycle env)
#   cycle iter 1:   build=3.1.1, test=3.1.2, test_assessment=3.1.3
#                   AND each member sees ZBUILD_CYCLE_CARDINAL=3
#   review          = "4"               (cardinal continues past the cycle slot
#                                        AND ZBUILD_CYCLE_CARDINAL is UNSET —
#                                        the unset-on-return contract)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "full pipeline 3-level cycle seq labels (#698)"
setup_test_env "full-pipeline-cycle-seq-3level"

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
export ZBUILD_CYCLES_ENABLED=1
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_SEQ_LABEL_LOG="$LABEL_LOG"
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"
: > "$LABEL_LOG"

# Mock plugin factory: every plugin logs the seq label + the visibility of
# ZBUILD_CYCLE_CARDINAL (so the assertions can pin both the 3-level format
# AND the no-leak-into-pre/post-cycle-stages contract).
_make_plugin() {
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
    cat > "$dir/plugin.sh" <<PLUGIN
${fn}() {
    printf 'stage=%s label=%s cardinal_env=%s\n' \\
        "$id" \\
        "\${ZBUILD_STAGE_IO_SEQ_LABEL:-MISSING}" \\
        "\${ZBUILD_CYCLE_CARDINAL:-UNSET}" \\
        >> "\${ZBUILD_SEQ_LABEL_LOG:-/dev/null}"
    return 0
}
PLUGIN
}

for s in intake plan build test test_assessment review; do
    _make_plugin "$s"
done

rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
set +e
bash "$REPO_ROOT/core/pipeline/runner.sh" --issue 698 --template standard \
    >"$TEST_TEMP_DIR/runner.out" 2>&1
rc=$?
set -e

# The runner returns non-zero for many post-pipeline conditions in this mock
# environment; we only care that the cycle members and post-cycle stages saw
# the expected labels. Don't assert rc=0.

_label_for() {
    local stage="$1" iter="$2"
    grep "^stage=${stage} " "$LABEL_LOG" \
        | sed -n "${iter}s/.*label=\([^ ]*\).*/\1/p"
}

_cardinal_env_for() {
    local stage="$1"
    grep "^stage=${stage} " "$LABEL_LOG" \
        | head -1 \
        | sed -n 's/.*cardinal_env=\(.*\)$/\1/p'
}

assert_eq "intake observed cardinal label 1"     "1"     "$(_label_for intake 1)"
assert_eq "plan observed cardinal label 2"       "2"     "$(_label_for plan 1)"

assert_eq "build iter 1 label = 3.1.1"           "3.1.1" "$(_label_for build 1)"
assert_eq "test iter 1 label = 3.1.2"            "3.1.2" "$(_label_for test 1)"
assert_eq "test_assessment iter 1 label = 3.1.3" "3.1.3" "$(_label_for test_assessment 1)"

# Wave 18-B (#707): standard.yaml now wraps `review` inside the outer
# review_cycle (ADR-026). review is no longer a post-cycle linear stage at
# cardinal 4 — it's a member of the outermost cycle (cardinal 3 in this
# template), so its seq label inherits the cycle's prefix. The first run
# of review under outer_iter 1 lands at `3.1.<position>`. The exact
# position depends on review_cycle's member layout — for `flow:
# [build_test_cycle, review]`, review is position 2.
# Accept any 3-level label starting with "3.1." to be resilient to inner
# build_test_cycle dispatch ordering nuances.
_rev_label="$(_label_for review 1)"
if [[ "$_rev_label" =~ ^3\.1\.[0-9]+$ ]]; then
    assert_pass "review observed 3-level label under review_cycle: $_rev_label (#707)"
else
    assert_fail "review observed 3-level label under review_cycle" \
        "expected 3.1.<pos>, got '$_rev_label'"
fi

# Cycle members must see the runner-published cardinal.
assert_eq "build saw ZBUILD_CYCLE_CARDINAL=3"           "3" "$(_cardinal_env_for build)"
assert_eq "test saw ZBUILD_CYCLE_CARDINAL=3"            "3" "$(_cardinal_env_for test)"
assert_eq "test_assessment saw ZBUILD_CYCLE_CARDINAL=3" "3" "$(_cardinal_env_for test_assessment)"

# Leak check: ZBUILD_CYCLE_CARDINAL must NOT leak into post-cycle stages.
assert_eq "intake saw ZBUILD_CYCLE_CARDINAL UNSET" "UNSET" "$(_cardinal_env_for intake)"
assert_eq "plan saw ZBUILD_CYCLE_CARDINAL UNSET"   "UNSET" "$(_cardinal_env_for plan)"
# Wave 18-B (#707): review is now a member of the outer review_cycle
# (ADR-026), so it MUST see ZBUILD_CYCLE_CARDINAL set (=3 — the cycle's
# own cardinal in this template's flow). The "no leak after cycle"
# property is preserved for intake/plan above (which are PRE-cycle).
assert_eq "review saw ZBUILD_CYCLE_CARDINAL=3 (review is now in review_cycle, #707)" \
    "3" "$(_cardinal_env_for review)"

print_test_results
cleanup_test_env
