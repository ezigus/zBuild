#!/usr/bin/env bash
# Tests: the engine sets the run's branch (#2367; intake did until then, #484).
#
# Fail-CLOSED: the `|| true` silent-failure pattern was the highest-severity
# finding from the silent-failure hunter on intake's version.
# Note: deliberately NOT using `set -e` — many tests below expect non-zero
# rc and we capture it via `rc=$?` immediately after.
set -uo pipefail
# Note: deliberately NOT using `set -e` — many tests below expect non-zero
# rc and we capture it via `rc=$?` immediately after.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "the engine sets the run's branch (#2367, #484)"

setup_test_env "run-branch-setup"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../scripts/lib/run-branch-setup.sh
source "$REPO_ROOT/scripts/lib/run-branch-setup.sh"
unset ZBUILD_REPO_ROOT ZBUILD_MAIN_REPO_ROOT ZBUILD_WORKSPACE_BRANCH

# ─── zbuild_run_branch_name: where the name comes from ───────────────────────
print_test_section "branch name"
_NR="$TEST_TEMP_DIR/name-repo"; mkdir -p "$_NR/.zbuild"
assert_eq "default: zbuild/issue-<n>" "zbuild/issue-1" "$(zbuild_run_branch_name 1 "" "" "")"
assert_eq "the template's pattern, {key} filled in" "work/issue-2" "$(zbuild_run_branch_name 2 "" "work/{key}" "")"
printf '# comment\nmine/{key}\n' > "$_NR/.zbuild/branch"
assert_eq ".zbuild/branch overrides the template" "mine/issue-3" "$(zbuild_run_branch_name 3 "" "work/{key}" "$_NR")"
assert_eq "ZBUILD_WORKSPACE_BRANCH overrides both" "ci/x" \
    "$(ZBUILD_WORKSPACE_BRANCH=ci/x zbuild_run_branch_name 3 "" "work/{key}" "$_NR")"
_gk="$(zbuild_run_key 0 "some goal")"
assert_eq "a goal run is keyed on its goal" "zbuild/$_gk" "$(zbuild_run_branch_name 0 "some goal" "" "")"

# ─── zbuild_run_branch_valid ──────────────────────────────────────────────────
print_test_section "branch-name validation"

_validate_rc() {
    local n="$1"; local rc
    zbuild_run_branch_valid "$n"; rc=$?
    echo "$rc"
}

assert_eq "valid name accepted"        "0" "$(_validate_rc "zbuild/issue-1-fix")"
assert_eq "empty rejected"             "1" "$(_validate_rc "")"
assert_eq "whitespace rejected"        "1" "$(_validate_rc "   ")"
assert_eq "leading dash rejected"      "1" "$(_validate_rc "-foo")"
assert_eq "path traversal rejected"    "1" "$(_validate_rc "../evil")"
assert_eq "double-dot rejected"        "1" "$(_validate_rc "foo..bar")"
assert_eq "space in name rejected"     "1" "$(_validate_rc "foo bar")"
assert_eq "tilde rejected"             "1" "$(_validate_rc "foo~bar")"

# ─── Integration: real git repo for idempotence + preflight ─────────────────
print_test_section "real git repo idempotence + preflight"

REPO="$(setup_git_temp_repo zbuild-484-repo)"
if [[ -z "$REPO" || ! -d "$REPO/.git" ]]; then
    assert_fail "setup_git_temp_repo created a usable repo" "no .git at $REPO"
    cleanup_test_env
    print_test_results
fi

# Keep state OUTSIDE the repo so it doesn't show as untracked → dirty tree.
STATE_DIR="$TEST_TEMP_DIR/state-484"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR"
echo '{"schema_version":1,"run_id":"t","issue":484,"stage_statuses":{}}' > "$STATE_FILE"

_reset_events() { : > "$ZBUILD_EVENTS_JSONL"; }
_event_count() { grep -c "\"$1\"" "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0; }

unset CI CI_MODE

# All state-changing tests run in the parent shell so HEAD changes persist.
cd "$REPO" || exit 1

# ── Test: the shared default-branch resolver resolves 'main' in this repo ──
# This repo has refs/heads/main (local fallback) and no remote.
# [SPEC-3] the shared resolver (scripts/lib/default-branch.sh, #1655) is in
# scope through run-branch-setup.sh.
resolved_branch="$(zbuild_resolve_default_branch 2>/dev/null)"
assert_eq "[SPEC-3] zbuild_resolve_default_branch resolves 'main' in main-default repo" \
    "main" "$resolved_branch"

# ── Test: first run creates branch ──
_reset_events
zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
assert_eq "first run rc=0" "0" "$rc"

cur="$(git symbolic-ref --short HEAD 2>/dev/null)"
assert_eq "branch checked out" "zbuild/issue-484" "$cur"
assert_eq "ZBUILD_RUN_BRANCH names it" "zbuild/issue-484" "${ZBUILD_RUN_BRANCH:-}"
assert_file_not_exists "no intake-branch.txt" "$STATE_DIR/intake-branch.txt"

created_count="$(_event_count 'outcome":"created')"
assert_gt "pipeline.branch.ready outcome=created" "$created_count" "0"

state_branch="$(jq -r '.branch // empty' "$STATE_FILE")"
assert_eq "pipeline-state.json .branch updated" \
    "zbuild/issue-484" "$state_branch"

# ── Test: re-run on same branch → noop ──
_reset_events
zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
assert_eq "noop run rc=0" "0" "$rc"
noop_count="$(_event_count 'outcome":"noop')"
assert_gt "outcome=noop when already on target" "$noop_count" "0"

# ── Test: switch back to main, then re-run → reused ──
git checkout -q main
_reset_events
zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
assert_eq "reuse run rc=0" "0" "$rc"
reused_count="$(_event_count 'outcome":"reused')"
assert_gt "outcome=reused for pre-existing branch" "$reused_count" "0"

# ── Test: ZBUILD_WORKSPACE_BRANCH override verbatim ──
git checkout -q main
_reset_events
ZBUILD_WORKSPACE_BRANCH="custom/override-branch" \
    zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
unset ZBUILD_WORKSPACE_BRANCH
assert_eq "env override rc=0" "0" "$rc"
cur="$(git symbolic-ref --short HEAD)"
assert_eq "env override branch name verbatim" "custom/override-branch" "$cur"

# ── Test: ZBUILD_WORKSPACE_BRANCH invalid rejected ──
git checkout -q main
_reset_events
ZBUILD_WORKSPACE_BRANCH="../evil" \
    zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
unset ZBUILD_WORKSPACE_BRANCH
assert_eq "invalid env override rc=1" "1" "$rc"
inv_count="$(_event_count "invalid_branch_name")"
assert_gt "invalid_branch_name refusal emitted" "$inv_count" "0"

# ── Test: dirty tree refusal ──
git checkout -q main
echo "dirty" > "$REPO/dirty.txt"
_reset_events
zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
assert_eq "dirty tree → rc=1" "1" "$rc"
dirty_count="$(_event_count "working_tree_dirty")"
assert_gt "refused with reason=working_tree_dirty" "$dirty_count" "0"

# Allow override
_reset_events
ZBUILD_ALLOW_DIRTY=1 \
    zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
assert_eq "ZBUILD_ALLOW_DIRTY=1 bypasses dirty refusal" "0" "$rc"
rm -f "$REPO/dirty.txt"
git checkout -q main 2>/dev/null
git clean -fdq 2>/dev/null || true

# ── Test: mid-merge refusal ──
git_dir="$REPO/.git"
echo "deadbeef" > "$git_dir/MERGE_HEAD"
_reset_events
zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
rm -f "$git_dir/MERGE_HEAD"
assert_eq "mid-merge → rc=1" "1" "$rc"
merge_count="$(_event_count "repo_state_merge")"
assert_gt "refused with reason=repo_state_merge" "$merge_count" "0"

# ── Test: mid-rebase refusal ──
mkdir -p "$git_dir/rebase-merge"
_reset_events
zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
rm -rf "$git_dir/rebase-merge"
assert_eq "mid-rebase → rc=1" "1" "$rc"
rebase_count="$(_event_count "repo_state_rebase")"
assert_gt "refused with reason=repo_state_rebase" "$rebase_count" "0"

# ── Test: not-a-git-repo refusal ──
NON_REPO="$TEST_TEMP_DIR/not-a-repo"
mkdir -p "$NON_REPO/state"
_reset_events
(cd "$NON_REPO" && zbuild_run_branch_setup "$NON_REPO/state" 484 "" "") \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
assert_eq "not-a-git-repo → rc=1" "1" "$rc"
gnf_count="$(_event_count "not_a_git_repo")"
assert_gt "refused with reason=not_a_git_repo" "$gnf_count" "0"

# ── Test: detached HEAD allowed with info event ──
git checkout -q main
echo extra > extra.txt
git add extra.txt
git commit -q -m extra
head_sha="$(git rev-parse HEAD)"
git checkout -q --detach "$head_sha"
_reset_events
zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
assert_eq "detached HEAD branch creation rc=0" "0" "$rc"
assert_eq "from detached HEAD: on the run's branch" "zbuild/issue-484" "$(git symbolic-ref --short HEAD 2>/dev/null)"

# ── Test: branch exists on remote only → adopt it ──
git checkout -q main
# Create a proper bare origin repo for realistic testing.
ORIGIN_REPO="$TEST_TEMP_DIR/origin.git"
mkdir -p "$ORIGIN_REPO"
git init --bare "$ORIGIN_REPO" >/dev/null 2>&1
# Add origin remote to the repo.
git remote add origin "$ORIGIN_REPO" 2>/dev/null || git remote set-url origin "$ORIGIN_REPO"
# Create and push a test branch to origin.
git checkout -q -b zbuild/issue-484-remote-only
echo "test content" > test_remote.txt
git add test_remote.txt
git commit -q -m "remote branch commit"
git push -q origin zbuild/issue-484-remote-only
# Delete the local branch to simulate remote-only state.
git checkout -q main
git branch -D zbuild/issue-484-remote-only

_reset_events
ZBUILD_WORKSPACE_BRANCH="zbuild/issue-484-remote-only" \
    zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
unset ZBUILD_WORKSPACE_BRANCH
assert_eq "remote-only branch adoption → rc=0" "0" "$rc"
adopted_count="$(_event_count 'outcome":"adopted')"
assert_gt "outcome=adopted" "$adopted_count" "0"
cur="$(git symbolic-ref --short HEAD)"
assert_eq "HEAD on adopted branch" "zbuild/issue-484-remote-only" "$cur"

# ── Test: fetch failure → refuse with error event ──
git checkout -q main
# Create a new test branch for fetch failure scenario.
fetch_fail_branch="zbuild/issue-484-fetch-fail"
# Create a remote tracking ref for this branch (so git show-ref will find it).
git update-ref "refs/remotes/origin/$fetch_fail_branch" HEAD
# Break the origin URL to force fetch failure.
git remote set-url origin "file:///nonexistent/repo.git"
_reset_events
ZBUILD_WORKSPACE_BRANCH="$fetch_fail_branch" \
    zbuild_run_branch_setup "$STATE_DIR" 484 "" "" \
    > "$TEST_TEMP_DIR/run-branch-setup-out.$$" 2>&1
rc=$?
unset ZBUILD_WORKSPACE_BRANCH
assert_eq "fetch failure → rc=1" "1" "$rc"
fetch_err_count="$(_event_count "fetch_failed")"
assert_gt "fetch_failed reason emitted on fetch error" "$fetch_err_count" "0"
# Restore origin to clean state.
git remote set-url origin "$ORIGIN_REPO"

# ─── Cleanup ────────────────────────────────────────────────────────────────
cd "$REPO_ROOT" || true
rm -f "$TEST_TEMP_DIR/run-branch-setup-out.$$"
cleanup_test_env
print_test_results
exit $((FAIL > 0))
