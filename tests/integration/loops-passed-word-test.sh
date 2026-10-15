#!/usr/bin/env bash
# tests/integration/loops-passed-word-test.sh — the engine's word on the run's
# loops starts unset each run (#2368, ADR-040).
#
# Why: merge and deploy act only on ZBUILD_RUN_LOOPS_PASSED=yes. A "yes" left in
# the environment (a nested run, a stale CI variable) must not reach a stage of
# a run whose own loops never said so.
#
#   W1 [change] a run with no loop: no stage sees an inherited "yes"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "the loops-passed word starts unset each run (#2368)"
setup_test_env "loops-passed-word"
_ZB_ID="$(zb_test_issue)"
export ZBUILD_RUN_ROOT="$TEST_TEMP_DIR/runroot"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
HOME_DIR="$TEST_TEMP_DIR/home"; mkdir -p "$HOME_DIR/.zbuild"
mock_plugin_factory "intake" "agent" 0 "" "" >/dev/null
mock_plugin_factory "build"  "agent" 0 "" "" >/dev/null
SEEN="$TEST_TEMP_DIR/seen"
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<EOF
build_run() {
    printf '%s' "\${ZBUILD_RUN_LOOPS_PASSED:-unset}" > "$SEEN"
    $(mock_result_line build)
    return 0
}
EOF
T="$(setup_git_temp_repo t)"; install_template_overlay "$T" runner-state-dir-minimal
( cd "$T" && env -u ZBUILD_STATE_DIR -u ZBUILD_STATE_ROOT -u ZBUILD_STATE_FILE \
    -u ZBUILD_EVENTS_DIR -u ZBUILD_EVENTS_JSONL -u ZBUILD_EVENTS_DB -u ZBUILD_REPO_ROOT \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_RUN_ROOT="$ZBUILD_RUN_ROOT" ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_RUN_ID=run-w1 HOME="$HOME_DIR" PATH="$PATH" ZBUILD_RUN_LOOPS_PASSED=yes \
    bash "$RUNNER" --issue "$_ZB_ID" --no-resume --template runner-state-dir-minimal ) >/dev/null 2>&1

print_test_section "W1: an inherited yes does not reach a stage"
assert_eq "[W1] a run with no loop: the stage sees no word" "unset" "$(cat "$SEEN" 2>/dev/null || echo none)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
