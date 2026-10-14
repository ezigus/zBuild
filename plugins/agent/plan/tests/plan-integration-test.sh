#!/usr/bin/env bash
# Integration test: plan stage end-to-end with a stubbed `claude` binary on PATH.
# Exercises route_to_model -> _route_call_claude across the subprocess boundary
# (real subshell, real exec). Since #2363 the model writes plan.json itself and
# the stage reads that file: the stub writes it to the path the prompt names.
#
#   I1 [change] the model writes a valid plan → rc 0, verdict pass
#   I2 [change] the model writes a valid plan, then its call fails → the plan
#               still counts
#   I3 [change] the model writes nothing and its call fails → rc 1, an error
#               result with the shared disposition for the failure
#   I4 [guard]  the prompt the model receives names the plan file
# shellcheck disable=SC2034  # PLAN_GOAL is read by plan-integration-lib.sh's _run_plan
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: plan — integration (real router, claude stub writes plan.json)"

setup_test_env "plugin-plan-integration"

# shellcheck source=plan-integration-lib.sh
source "$SCRIPT_DIR/plan-integration-lib.sh"
_plan_error_boundary_env

_PJ="$ARTIFACTS_DIR/plan.json"
_PLAN_SRC="$TEST_TEMP_DIR/model-plan.json"
printf '%s\n' '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"Stop a hung hook at its limit.","areas":["core/"]}],"open_questions":[]}' > "$_PLAN_SRC"

print_test_section "I1: the model writes a valid plan"
rm -f "$_PJ"; : > "$ZBUILD_EVENTS_JSONL"
_install_plan_writer_claude --plan-file "$_PLAN_SRC" --rc 0
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "[I1] plan_run rc=0" "0" "$rc"
assert_eq "[I1] outcome pass" "pass" "$(jq -r .outcome "$_PJ" 2>/dev/null)"
assert_eq "[I1] the model's work item is the plan" "Stop a hung hook at its limit." \
    "$(jq -r '.steps[0].description' "$_PJ" 2>/dev/null)"

print_test_section "I2: a valid plan written before the call failed still counts"
rm -f "$_PJ"; : > "$ZBUILD_EVENTS_JSONL"
_install_plan_writer_claude --plan-file "$_PLAN_SRC" --rc 124
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "[I2] plan_run rc=0" "0" "$rc"
assert_eq "[I2] outcome pass" "pass" "$(jq -r .outcome "$_PJ" 2>/dev/null)"

print_test_section "I3: nothing written and the call failed"
rm -f "$_PJ"; : > "$ZBUILD_EVENTS_JSONL"
_install_plan_writer_claude --plan-file "$TEST_TEMP_DIR/none.json" --rc 124
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "[I3] plan_run rc=1" "1" "$rc"
assert_eq "[I3] contract 3: no verdict field" "null" "$(jq -r .verdict "$_PJ" 2>/dev/null)"
assert_eq "[I3] the shared word for a timeout is the outcome" "timed_out" "$(jq -r .outcome "$_PJ" 2>/dev/null)"
assert_eq "[I3] reason no_plan_written" "no_plan_written" "$(jq -r .reason "$_PJ" 2>/dev/null)"

print_test_section "I4: the model is told where to write"
_REC="$TEST_TEMP_DIR/recorded-prompt.txt"
install_envelope_mock_claude --file "$CANNED_RESPONSE_FILE" --record-prompt "$_REC"
rm -f "$_PJ"
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; set -e
assert_contains "[I4] the prompt names the plan file" "$(cat "$_REC" 2>/dev/null)" "$_PJ"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
