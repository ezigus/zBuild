#!/usr/bin/env bash
# tests/unit/run-branch-start-test.sh — what the engine records when it sets the
# run's branch (#2367; intake did this until then: #614 starting commit, #1265
# untracked files already there).
#
#   S1 [change] ZBUILD_RUN_START_COMMIT is HEAD after the branch is checked out
#   S2 [change] ZBUILD_RUN_UNTRACKED_AT_START lists the untracked files already
#               there (NUL-separated), and build's loader reads it, so a stray
#               from an earlier run is never counted as build's own
#   S3 [change] pipeline.branch.ready says which branch, how, and from where
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "the engine records the run's starting point (#2367)"
setup_test_env "run-branch-start"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"; : > "$ZBUILD_EVENTS_JSONL"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../scripts/lib/run-branch-setup.sh
source "$REPO_ROOT/scripts/lib/run-branch-setup.sh"
unset ZBUILD_REPO_ROOT ZBUILD_MAIN_REPO_ROOT ZBUILD_WORKSPACE_BRANCH CI GITHUB_ACTIONS

REPO="$(setup_git_temp_repo run-branch-start)"
SD="$TEST_TEMP_DIR/state"; mkdir -p "$SD"
cd "$REPO" || exit 1
mkdir -p config/templates
printf 'stray\n' > config/templates/left-by-earlier-run.yaml

ZBUILD_ALLOW_DIRTY=1 zbuild_run_branch_setup "$SD" 614 "" "" > "$TEST_TEMP_DIR/out" 2>&1
assert_eq "setup rc=0" "0" "$?"

print_test_section "S1: the starting commit"
assert_eq "[S1] ZBUILD_RUN_START_COMMIT is HEAD on the run's branch" \
    "$(git rev-parse HEAD)" "${ZBUILD_RUN_START_COMMIT:-}"
assert_eq "[S1] ...and HEAD is on the run's branch" "zbuild/issue-614" "$(git symbolic-ref --short HEAD)"

print_test_section "S2: the untracked files already there"
_u="$(tr '\0' '\n' < "${ZBUILD_RUN_UNTRACKED_AT_START:-/nonexistent}" 2>/dev/null)"
if grep -Fxq 'config/templates/left-by-earlier-run.yaml' <<< "$_u"; then
    assert_pass "[S2] the stray is listed"
else
    assert_fail "[S2] the stray is listed" "got: $_u"
fi
# shellcheck source=../../plugins/agent/build/lib/diff.sh
source "$REPO_ROOT/plugins/agent/build/lib/diff.sh"
_loaded="$(_build_load_preexisting_untracked)"
if [[ -n "$_loaded" ]] && grep -Fxq 'config/templates/left-by-earlier-run.yaml' "$_loaded"; then
    assert_pass "[S2] build's loader reads the engine's list"
else
    assert_fail "[S2] build's loader reads the engine's list" "loaded: ${_loaded:-none}"
fi
rm -f "$_loaded"

print_test_section "S3: the event"
_ev="$(grep '"pipeline.branch.ready"' "$ZBUILD_EVENTS_JSONL" | tail -1)"
assert_eq "[S3] names the branch" "zbuild/issue-614" "$(jq -r '.data.branch' <<< "$_ev")"
assert_eq "[S3] says it was created" "created" "$(jq -r '.data.outcome' <<< "$_ev")"
assert_eq "[S3] names the starting commit" "$ZBUILD_RUN_START_COMMIT" "$(jq -r '.data.start' <<< "$_ev")"

cd "$REPO_ROOT" || true
cleanup_test_env
print_test_results
exit $((FAIL > 0))
