#!/usr/bin/env bash
# Integration test (#698, Wave 16-A; #718, Wave 19-B): full pipeline with cycles
# enabled exports N-level recursive seq labels for cycle members via
# ZBUILD_SEQ_PREFIX prefix accumulation.
#
# Drives runner.sh end-to-end with the standard template (3 top-level dispatch
# units: intake, plan, cycle:review_cycle — where review_cycle's flow is
# [build_test_cycle, review], and build_test_cycle's flow is
# [build, test, test_assessment]). Mocks plugins to log the observed
# ZBUILD_STAGE_IO_SEQ_LABEL and the visibility of ZBUILD_SEQ_PREFIX.
# The mock test_assessment + mock review default to verdict=pass; both cycles
# converge in a single outer/inner iter — that one iter is enough to verify
# the recursive prefix shape, because the same code path emits every iter's
# label.
#
# Pinned assertions (#754: design is now cardinal 3, review_cycle is cardinal 4):
#   intake          = "1"               (linear cardinal, no cycle env)
#   plan            = "2"               (linear cardinal, no cycle env)
#   design          = "3"               (linear cardinal, no cycle env)
#   review_cycle (cardinal 4) → build_test_cycle (pos 1) → leaves at
#     prefix "4.1.1":
#       build           = "4.1.1.1.1"
#       test            = "4.1.1.1.2"
#       test_assessment = "4.1.1.1.3"
#   review_cycle (cardinal 4) → review (pos 2):
#       review          = "4.1.2"        (3 segments — review is a direct leaf
#                                         member of review_cycle, not nested)
#
# Wave 19-B also requires ZBUILD_SEQ_PREFIX visibility inside cycle members
# (the prefix the orchestrator passes down) AND no leak to pre-cycle stages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "full pipeline N-level recursive cycle seq labels (#698, #718)"
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
# ZBUILD_SEQ_PREFIX (so the assertions can pin both the recursive prefix shape
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
    printf 'stage=%s label=%s prefix_env=%s\n' \\
        "$id" \\
        "\${ZBUILD_STAGE_IO_SEQ_LABEL:-MISSING}" \\
        "\${ZBUILD_SEQ_PREFIX:-UNSET}" \\
        >> "\${ZBUILD_SEQ_LABEL_LOG:-/dev/null}"
    return 0
}
PLUGIN
}

# Override for impact: declares a primary output so exit_when can read the
# verdict, and writes {"verdict":"complete"} so plan_impact_cycle converges
# after iter 1 instead of running to max_iterations.
_make_impact_plugin() {
    local dir="$PLUGINS_ROOT/agent/impact"
    cat > "$dir/manifest.yaml" <<'EOF'
id: impact
name: Test impact
kind: agent
version: 0.0.1
hooks:
  run: impact_run
requires:
  core:
    - redaction
outputs:
  - id: impact_out
    path: ${artifact_dir}/impact.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
impact_run() {
    printf 'stage=impact label=%s prefix_env=%s\n' \
        "${ZBUILD_STAGE_IO_SEQ_LABEL:-MISSING}" \
        "${ZBUILD_SEQ_PREFIX:-UNSET}" \
        >> "${ZBUILD_SEQ_LABEL_LOG:-/dev/null}"
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    printf '{"verdict":"complete"}' > "$state_dir/artifacts/impact.json"
    return 0
}
PLUG
}

for s in intake plan impact design build test test_assessment cq-preflight cq-audit-plan cq-cycle cq-backtrack review; do
    _make_plugin "$s"
done
_make_impact_plugin

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

_prefix_env_for() {
    local stage="$1"
    grep "^stage=${stage} " "$LABEL_LOG" \
        | head -1 \
        | sed -n 's/.*prefix_env=\(.*\)$/\1/p'
}

assert_eq "intake observed cardinal label 1"     "1"       "$(_label_for intake 1)"
# #746: plan is now inside plan_impact_cycle (cardinal 2, iter 1, pos 1).
assert_eq "plan observed label 2.1.1"            "2.1.1"   "$(_label_for plan 1)"
assert_eq "impact observed label 2.1.2"          "2.1.2"   "$(_label_for impact 1)"

# Wave 19-B (#718): build/test/test_assessment live inside review_cycle (card 4)
# → build_test_cycle (pos 1, iter 1) → leaves at "4.1.1.<inner_iter>.<inner_pos>".
# #754: design is now cardinal 3, pushing review_cycle to cardinal 4.
assert_eq "build iter 1 label = 4.1.1.1.1"           "4.1.1.1.1" "$(_label_for build 1)"
assert_eq "test iter 1 label = 4.1.1.1.2"            "4.1.1.1.2" "$(_label_for test 1)"
assert_eq "test_assessment iter 1 label = 4.1.1.1.3" "4.1.1.1.3" "$(_label_for test_assessment 1)"

# #755: cq-* stages are direct members of review_cycle at positions 2-5.
# review shifts from pos 2 to pos 6 → "4.1.6".
assert_eq "cq-preflight iter 1 label = 4.1.2"        "4.1.2"     "$(_label_for cq-preflight 1)"
assert_eq "cq-audit-plan iter 1 label = 4.1.3"       "4.1.3"     "$(_label_for cq-audit-plan 1)"
assert_eq "cq-cycle iter 1 label = 4.1.4"            "4.1.4"     "$(_label_for cq-cycle 1)"
assert_eq "cq-backtrack iter 1 label = 4.1.5"        "4.1.5"     "$(_label_for cq-backtrack 1)"
assert_eq "review iter 1 label = 4.1.6"              "4.1.6"     "$(_label_for review 1)"

# Inside the nested build_test_cycle, members must see ZBUILD_SEQ_PREFIX="4.1.1"
# (review_cycle's prefix 4 → its iter 1, pos 1 = build_test_cycle).
assert_eq "build saw ZBUILD_SEQ_PREFIX=4.1.1"           "4.1.1" "$(_prefix_env_for build)"
assert_eq "test saw ZBUILD_SEQ_PREFIX=4.1.1"            "4.1.1" "$(_prefix_env_for test)"
assert_eq "test_assessment saw ZBUILD_SEQ_PREFIX=4.1.1" "4.1.1" "$(_prefix_env_for test_assessment)"

# #755: cq-* stages are direct leaf members of review_cycle; they see prefix "4".
assert_eq "cq-preflight saw ZBUILD_SEQ_PREFIX=4"  "4" "$(_prefix_env_for cq-preflight)"
assert_eq "cq-audit-plan saw ZBUILD_SEQ_PREFIX=4" "4" "$(_prefix_env_for cq-audit-plan)"
assert_eq "cq-cycle saw ZBUILD_SEQ_PREFIX=4"      "4" "$(_prefix_env_for cq-cycle)"
assert_eq "cq-backtrack saw ZBUILD_SEQ_PREFIX=4"  "4" "$(_prefix_env_for cq-backtrack)"

# Leak check: ZBUILD_SEQ_PREFIX must NOT leak into pre-cycle stages.
assert_eq "intake saw ZBUILD_SEQ_PREFIX UNSET" "UNSET" "$(_prefix_env_for intake)"
# #746: plan + impact are inside plan_impact_cycle (cardinal 2); they see prefix "2".
assert_eq "plan saw ZBUILD_SEQ_PREFIX=2"   "2" "$(_prefix_env_for plan)"
assert_eq "impact saw ZBUILD_SEQ_PREFIX=2" "2" "$(_prefix_env_for impact)"
# review is a direct leaf member of review_cycle so it sees the outer prefix "4".
assert_eq "review saw ZBUILD_SEQ_PREFIX=4 (direct member of review_cycle)" \
    "4" "$(_prefix_env_for review)"

print_test_results
cleanup_test_env
