#!/usr/bin/env bash
# tests/integration/issue-check-stops-run-test.sh — the real runner over the
# simple template's stub stages (#2614, ADR-074, ADR-068 §3).
#
#   SR1 [code] an issue-check that finds the issue needs rewriting stops the run
#              before design, and the stop line names it with its reason
#   SR2 [code] a failed hydrate (not blocking) holds nothing back: pr still runs
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "issue-check stops a run before design; a failed hydrate does not (#2614)"
setup_test_env "issue-check-stops-run"

_ZB_REPO="$(zb_test_repo issue-check-stops-run)"
_ZB_GOAL="$(zb_test_goal issue-check-stops-run)"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=1 ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZB_STUB_ROOT="$REPO_ROOT"
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"
# shellcheck source=../lib/simple-run-stubs.sh
source "$REPO_ROOT/tests/lib/simple-run-stubs.sh"
simple_stubs_roster
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TEMP_DIR/bin/claude"; chmod +x "$TEST_TEMP_DIR/bin/claude"

# _stub_stage <id> <role> <outcome> <reason> <rc> — a stage that ends <outcome>.
_stub_stage() {
    local dir="$PLUGINS_ROOT/agent/$1" fn="${1//-/_}_run"
    rm -rf "$dir"; mock_plugin_factory "$1" agent 0 "" "$2" >/dev/null
    cat > "$dir/plugin.sh" <<PLUG
$fn() {
    local state_dir; state_dir="\$(dirname "\$2")"; mkdir -p "\$state_dir/artifacts"
    source "\$STAGE_RESULT_LIB"
    stage_result_write "\$state_dir/artifacts/$1-result.json" $3 "$4"
    return $5
}
PLUG
}
_ran() { jq -r --arg s "$1" 'select(.type=="plugin.run.start" and .stage==$s) | .stage' "$EVENTS_JSONL" 2>/dev/null | grep -c . || true; }

print_test_section "SR1: the issue needs rewriting"
_stub_stage issue-check issue_check misconfigured "the issue needs rewriting: 1 of 2 requirement(s) no longer hold — RQSKIP-1 is already true today" 1
_run_pipeline
assert_eq "[SR1] design never ran" "0" "$(_ran design)"
assert_eq "[SR1] the run failed" "failed" "$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" | tail -1)"
assert_contains "[SR1] the stop line names issue-check and its reason" "$(cat "$TEST_TEMP_DIR/runner.stderr")" \
    "issue-check stopped the run — the issue needs rewriting: 1 of 2 requirement(s) no longer hold"

print_test_section "SR2: a failed hydrate holds nothing back"
_make_plugin "issue-check" "issue_check"
_stub_stage hydrate hydrate fail "the saved state could not be restored" 0
_run_pipeline
assert_eq "[SR2] hydrate ran and failed" "1" "$(_ran hydrate)"
assert_gt "[SR2] pr still ran" "$(_ran pr)" "0"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
