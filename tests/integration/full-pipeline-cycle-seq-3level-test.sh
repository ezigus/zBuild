#!/usr/bin/env bash
# Integration test (#698, Wave 16-A): full pipeline with cycles enabled exports
# 3-level seq labels for cycle members and continues the cardinal for linear
# stages after the cycle.
#
# Drives runner.sh end-to-end with the standard template (4 dispatch units:
# intake, plan, cycle:build_test_cycle, review). Mocks plugins to log the
# observed ZBUILD_STAGE_IO_SEQ_LABEL and the visibility of ZBUILD_CYCLE_CARDINAL.
# The mock test_assessment converges on iter 1 so the loop runs once — the
# 3-level prefix and the cardinal-leak guarantee are both verifiable from a
# single iter (the same code path emits every iter's label).
#
# Pinned assertions:
#   intake          = "1"               (linear cardinal, no cycle env)
#   plan            = "2"               (linear cardinal, no cycle env)
#   cycle iter 1:   build=3.1.1, test=3.1.2, test_assessment=3.1.3
#                   AND each member sees ZBUILD_CYCLE_CARDINAL=3
#   review          = "4"               (cardinal continues past the cycle slot
#                                        AND ZBUILD_CYCLE_CARDINAL is UNSET —
#                                        the unset-on-return contract)
set -uo pipefail

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
ITER_STATE="$TEST_TEMP_DIR/iter.state"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=1
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_SEQ_LABEL_LOG="$LABEL_LOG"
export ZBUILD_ITER_STATE="$ITER_STATE"
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"
: > "$LABEL_LOG"
printf '0\n' > "$ITER_STATE"

# Mock plugin factory: logs observed seq label + the cycle cardinal env (to
# verify no leak into post-cycle stages). For test_assessment, drives convergence
# on iter 2 by writing test_assessment.json with verdict=pass; iter 1 = fail.
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
    local stage_dir="\${ZBUILD_STAGE_DIR:-}"
    local iter="\${ZBUILD_CYCLE_ITER:-0}"
    if [[ "$id" == "test_assessment" && -n "\$stage_dir" ]]; then
        local verdict="fail"
        [[ "\$iter" -ge 2 ]] && verdict="pass"
        printf '{"schema_version":1,"verdict":"%s","summary":"x"}\n' "\$verdict" \\
            > "\$stage_dir/test_assessment.json" 2>/dev/null || true
    fi
    if [[ "$id" == "review" && -n "\$stage_dir" ]]; then
        printf '{"schema_version":1,"verdict":"approve","confidence":0.9,"issues":[],"summary":"x"}\n' \\
            > "\$stage_dir/review.json" 2>/dev/null || true
    fi
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

assert_eq "review observed cardinal label 4"     "4"     "$(_label_for review 1)"

# Cycle members must see the runner-published cardinal.
assert_eq "build saw ZBUILD_CYCLE_CARDINAL=3"           "3" "$(_cardinal_env_for build)"
assert_eq "test saw ZBUILD_CYCLE_CARDINAL=3"            "3" "$(_cardinal_env_for test)"
assert_eq "test_assessment saw ZBUILD_CYCLE_CARDINAL=3" "3" "$(_cardinal_env_for test_assessment)"

# Leak check: ZBUILD_CYCLE_CARDINAL must NOT leak into post-cycle stages.
assert_eq "intake saw ZBUILD_CYCLE_CARDINAL UNSET" "UNSET" "$(_cardinal_env_for intake)"
assert_eq "plan saw ZBUILD_CYCLE_CARDINAL UNSET"   "UNSET" "$(_cardinal_env_for plan)"
assert_eq "review saw ZBUILD_CYCLE_CARDINAL UNSET (no leak after cycle)" \
    "UNSET" "$(_cardinal_env_for review)"

print_test_results
cleanup_test_env
