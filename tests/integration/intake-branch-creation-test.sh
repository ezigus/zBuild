#!/usr/bin/env bash
# Tests: end-to-end intake_run in a real git repo creates the workspace
# branch and records it in state. Subprocess-boundary integration so the
# fail-closed path is exercised the same way the runner invokes it.
# Issue #484.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# #888: this file asserts IN-PLACE branch semantics (the main tree's HEAD moves,
# main-tree strays are visible). Worktree isolation is default-on and changes both
# — correctly: the branch lands in the per-run worktree and the developer's tree is
# left untouched. Pin this file to in-place mode so it keeps testing what it was
# written to test; worktree-mode behaviour is covered by
# tests/integration/intake-worktree-isolation-test.sh.
export ZBUILD_NO_WORKTREE=1


print_test_header "intake branch creation — subprocess + real git repo (#484)"

setup_test_env "intake-branch-int"

REPO="$(setup_git_temp_repo zbuild-484-int-repo)"
if [[ -z "$REPO" || ! -d "$REPO/.git" ]]; then
    assert_fail "setup_git_temp_repo created a usable repo" "no .git at $REPO"
    cleanup_test_env
    print_test_results
fi

# State outside the repo so .zbuild-state isn't an untracked file.
STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR"
echo '{"schema_version":1,"run_id":"int","issue":484,"stage_statuses":{}}' > "$STATE_FILE"

# Minimal platforms.json so intake doesn't fall back unexpectedly.
jq -n '{schema_version:1, detected:["generic"], overrides:[], updated_at:"2026-01-01T00:00:00Z"}' \
    > "$STATE_DIR/platforms.json"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# ── Run intake_run from a forked subprocess (mirrors how runner.sh invokes
#    plugins): a fresh bash interpreter so we exercise the real source/init
#    chain, not state inherited from this shell.
set +e
# #632: this test exercises branch-creation mechanics, not the closed-issue
# gate or CI-mode gate. Bypass both so it runs identically on macOS and Linux
# CI:
#  - GHA sets GITHUB_REPOSITORY → gh resolves issue #484 as CLOSED → refuse
#  - GHA sets CI=true → plugin requires ZBUILD_WORKSPACE_BRANCH override → refuse
subprocess_out="$(
    env -u CI \
    ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR" \
    ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL" \
    ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DB" \
    ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA" \
    ZBUILD_GOAL="add branch creation to intake" \
    ZBUILD_ISSUE=484 \
    ZBUILD_ALLOW_CLOSED_ISSUE=1 \
    bash -c "
        set -uo pipefail
        cd '$REPO'
        source '$REPO_ROOT/scripts/lib/helpers.sh'
        source '$REPO_ROOT/core/event-bus/event-bus.sh'
        source '$REPO_ROOT/plugins/agent/intake/plugin.sh'
        intake_run 'intake' '$STATE_FILE'
    " 2>&1
)"
rc=$?
set -e

assert_eq "intake_run subprocess rc=0" "0" "$rc"

cur_branch="$(cd "$REPO" && git symbolic-ref --short HEAD 2>/dev/null)"
assert_eq "real repo HEAD is on derived branch" \
    "zbuild/issue-484-add-branch-creation-to-intake" "$cur_branch"

assert_file_exists "state/intake.md written" "$STATE_DIR/intake.md"
assert_file_exists "state/intake-branch.txt written" "$STATE_DIR/intake-branch.txt"

br_text="$(cat "$STATE_DIR/intake-branch.txt")"
assert_eq "intake-branch.txt records the branch name" \
    "zbuild/issue-484-add-branch-creation-to-intake" "$br_text"

state_branch="$(jq -r '.branch // empty' "$STATE_FILE")"
assert_eq "pipeline-state.json .branch field set" \
    "zbuild/issue-484-add-branch-creation-to-intake" "$state_branch"

# Exactly one intake.branch.created event with full payload.
created_lines="$(grep '"intake.branch.created"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
created_count="$(printf '%s\n' "$created_lines" | grep -c . || true)"
assert_eq "exactly one intake.branch.created event" "1" "$created_count"

# Payload must contain branch + base + previous_head fields.
branch_field="$(printf '%s' "$created_lines" | jq -r '.data.branch // empty' 2>/dev/null | tail -1)"
assert_eq "event payload branch matches" \
    "zbuild/issue-484-add-branch-creation-to-intake" "$branch_field"

base_field="$(printf '%s' "$created_lines" | jq -r '.data.base // empty' 2>/dev/null | tail -1)"
if [[ -n "$base_field" && "$base_field" != "unknown" ]]; then
    assert_pass "event payload base SHA present ($base_field)"
else
    assert_fail "event payload base SHA present" "got: $base_field"
fi

# Re-invoke: subsequent call should emit a reused or noop event (no second created).
set +e
env -u CI \
ZBUILD_GOAL="add branch creation to intake" \
ZBUILD_ISSUE=484 \
ZBUILD_ALLOW_CLOSED_ISSUE=1 \
bash -c "
    set -uo pipefail
    cd '$REPO'
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/core/event-bus/event-bus.sh'
    source '$REPO_ROOT/plugins/agent/intake/plugin.sh'
    intake_run 'intake' '$STATE_FILE'
" > /dev/null 2>&1
rc2=$?
set -e
assert_eq "second intake_run rc=0" "0" "$rc2"

reused_or_noop="$(grep -E '"intake.branch.(reused|noop)"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_gt "second run emits reused or noop" "$reused_or_noop" "0"

still_one_created="$(grep -c '"intake.branch.created"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "still exactly one intake.branch.created across both runs" "1" "$still_one_created"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
