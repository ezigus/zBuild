#!/usr/bin/env bash
# Tests: plugins/agent/intake — branch creation helpers (issue #484)
#
# Mirrors shipwright legacy/scripts/lib/pipeline-stages-intake.sh:66-94 but
# verifies fail-CLOSED behavior — the `|| true` silent-failure pattern was
# the highest-severity finding from the silent-failure hunter.
set -uo pipefail
# Note: deliberately NOT using `set -e` — many tests below expect non-zero
# rc and we capture it via `rc=$?` immediately after.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: intake (branch creation — issue #484)"

setup_test_env "intake-branch"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../../../plugins/agent/intake/plugin.sh
source "$REPO_ROOT/plugins/agent/intake/plugin.sh"

# ─── _intake_derive_branch_name: slug rules ──────────────────────────────────
print_test_section "slug derivation"

assert_eq "lowercase passthrough" \
    "zbuild/issue-1-fix-bug" "$(_intake_derive_branch_name 1 "fix bug")"
assert_eq "uppercase lowercased" \
    "zbuild/issue-1-fix-the-login-flow" \
    "$(_intake_derive_branch_name 1 "Fix the Login Flow")"
assert_eq "special chars become hyphens" \
    "zbuild/issue-2-fix-bug-with-foo-bar" \
    "$(_intake_derive_branch_name 2 "fix: bug with foo/bar!")"
assert_eq "consecutive non-alphanum collapsed to one hyphen" \
    "zbuild/issue-3-a-b" \
    "$(_intake_derive_branch_name 3 "a   ///   b")"

slug40="$(_intake_derive_branch_name 4 "this-title-is-very-long-and-exceeds-the-forty-char-limit-for-sure")"
slug_part="${slug40#zbuild/issue-4-}"
slug_len=${#slug_part}
if [[ $slug_len -le 40 ]]; then
    assert_pass "40-char slug boundary respected (got len=$slug_len)"
else
    assert_fail "40-char slug boundary respected" "len=$slug_len exceeded 40"
fi

exactly40="0123456789012345678901234567890123456789"
exact_result="$(_intake_derive_branch_name 5 "$exactly40")"
assert_eq "exactly-40 input preserved" \
    "zbuild/issue-5-$exactly40" "$exact_result"

big="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
big_result="$(_intake_derive_branch_name 6 "$big")"
big_slug="${big_result#zbuild/issue-6-}"
assert_eq "41+ char input cut to 40" "40" "${#big_slug}"

assert_eq "empty title → untitled" \
    "zbuild/issue-7-untitled" "$(_intake_derive_branch_name 7 "")"
assert_eq "punctuation-only title → untitled" \
    "zbuild/issue-8-untitled" "$(_intake_derive_branch_name 8 "!!!---???")"
assert_eq "missing issue → issue-0" \
    "zbuild/issue-0-something" "$(_intake_derive_branch_name 0 "something")"
assert_eq "trailing hyphen stripped" \
    "zbuild/issue-9-fix" "$(_intake_derive_branch_name 9 "fix!!!")"

# ─── _intake_validate_branch_name ─────────────────────────────────────────────
print_test_section "branch-name validation"

_validate_rc() {
    local n="$1"; local rc
    _intake_validate_branch_name "$n"; rc=$?
    echo "$rc"
}

assert_eq "valid name accepted"        "0" "$(_validate_rc "zbuild/issue-1-fix")"
assert_eq "empty rejected"             "2" "$(_validate_rc "")"
assert_eq "whitespace rejected"        "2" "$(_validate_rc "   ")"
assert_eq "leading dash rejected"      "2" "$(_validate_rc "-foo")"
assert_eq "path traversal rejected"    "2" "$(_validate_rc "../evil")"
assert_eq "double-dot rejected"        "2" "$(_validate_rc "foo..bar")"
assert_eq "space in name rejected"     "2" "$(_validate_rc "foo bar")"
assert_eq "tilde rejected"             "2" "$(_validate_rc "foo~bar")"

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

# #633: GHA sets CI=true; intake plugin's CI-mode gate then requires
# ZBUILD_WORKSPACE_BRANCH override. This test exercises the auto-derive path,
# so unset CI for the rest of the script. (macOS runs this without CI set
# anyway; Linux CI is the only environment where this matters.)
unset CI CI_MODE

# All state-changing tests run in the parent shell so HEAD changes persist.
cd "$REPO" || exit 1

# ── Test: first run creates branch ──
_reset_events
_intake_create_workspace_branch "$STATE_DIR" 484 "fix the branch creation" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
assert_eq "first run rc=0" "0" "$rc"

cur="$(git symbolic-ref --short HEAD 2>/dev/null)"
assert_eq "branch checked out" "zbuild/issue-484-fix-the-branch-creation" "$cur"
assert_file_exists "intake-branch.txt created" "$STATE_DIR/intake-branch.txt"
br_file="$(cat "$STATE_DIR/intake-branch.txt")"
assert_eq "intake-branch.txt content" "zbuild/issue-484-fix-the-branch-creation" "$br_file"

created_count="$(_event_count "intake.branch.created")"
assert_gt "intake.branch.created emitted" "$created_count" "0"

state_branch="$(jq -r '.branch // empty' "$STATE_FILE")"
assert_eq "pipeline-state.json .branch updated" \
    "zbuild/issue-484-fix-the-branch-creation" "$state_branch"

# ── Test: re-run on same branch → noop ──
_reset_events
_intake_create_workspace_branch "$STATE_DIR" 484 "fix the branch creation" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
assert_eq "noop run rc=0" "0" "$rc"
noop_count="$(_event_count "intake.branch.noop")"
assert_gt "intake.branch.noop emitted when already on target" "$noop_count" "0"

# ── Test: switch back to main, then re-run → reused ──
git checkout -q main
_reset_events
_intake_create_workspace_branch "$STATE_DIR" 484 "fix the branch creation" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
assert_eq "reuse run rc=0" "0" "$rc"
reused_count="$(_event_count "intake.branch.reused")"
assert_gt "intake.branch.reused emitted for pre-existing branch" "$reused_count" "0"

# ── Test: ZBUILD_WORKSPACE_BRANCH override verbatim ──
git checkout -q main
_reset_events
ZBUILD_WORKSPACE_BRANCH="custom/override-branch" \
    _intake_create_workspace_branch "$STATE_DIR" 484 "ignored title" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
unset ZBUILD_WORKSPACE_BRANCH
assert_eq "env override rc=0" "0" "$rc"
cur="$(git symbolic-ref --short HEAD)"
assert_eq "env override branch name verbatim" "custom/override-branch" "$cur"

# ── Test: ZBUILD_WORKSPACE_BRANCH invalid rejected ──
git checkout -q main
_reset_events
ZBUILD_WORKSPACE_BRANCH="../evil" \
    _intake_create_workspace_branch "$STATE_DIR" 484 "x" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
unset ZBUILD_WORKSPACE_BRANCH
assert_eq "invalid env override rc=2" "2" "$rc"
inv_count="$(_event_count "intake.refused.invalid_branch_name")"
assert_gt "invalid_branch_name refusal emitted" "$inv_count" "0"

# ── Test: CI mode + missing env → refuse ──
_reset_events
unset ZBUILD_WORKSPACE_BRANCH WORKSPACE_BRANCH 2>/dev/null || true
CI=true _intake_create_workspace_branch "$STATE_DIR" 484 "x" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
assert_eq "CI mode + no env → rc=2" "2" "$rc"
ci_err_count="$(_event_count "ci_workspace_branch_unset")"
assert_gt "CI refusal includes ci_workspace_branch_unset reason" "$ci_err_count" "0"

# ── Test: dirty tree refusal ──
git checkout -q main
echo "dirty" > "$REPO/dirty.txt"
_reset_events
_intake_create_workspace_branch "$STATE_DIR" 484 "x" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
assert_eq "dirty tree → rc=2" "2" "$rc"
dirty_count="$(_event_count "intake.refused.dirty_tree")"
assert_gt "intake.refused.dirty_tree emitted" "$dirty_count" "0"

# Allow override
_reset_events
ZBUILD_INTAKE_ALLOW_DIRTY=1 \
    _intake_create_workspace_branch "$STATE_DIR" 484 "fix dirty override" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
assert_eq "ZBUILD_INTAKE_ALLOW_DIRTY=1 bypasses dirty refusal" "0" "$rc"
rm -f "$REPO/dirty.txt"
git checkout -q main 2>/dev/null
git clean -fdq 2>/dev/null || true

# ── Test: mid-merge refusal ──
git_dir="$REPO/.git"
echo "deadbeef" > "$git_dir/MERGE_HEAD"
_reset_events
_intake_create_workspace_branch "$STATE_DIR" 484 "x" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
rm -f "$git_dir/MERGE_HEAD"
assert_eq "mid-merge → rc=2" "2" "$rc"
merge_count="$(_event_count "repo_state_merge")"
assert_gt "intake.refused.repo_state with reason=repo_state_merge" "$merge_count" "0"

# ── Test: mid-rebase refusal ──
mkdir -p "$git_dir/rebase-merge"
_reset_events
_intake_create_workspace_branch "$STATE_DIR" 484 "x" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
rm -rf "$git_dir/rebase-merge"
assert_eq "mid-rebase → rc=2" "2" "$rc"
rebase_count="$(_event_count "repo_state_rebase")"
assert_gt "intake.refused.repo_state with reason=repo_state_rebase" "$rebase_count" "0"

# ── Test: not-a-git-repo refusal ──
NON_REPO="$TEST_TEMP_DIR/not-a-repo"
mkdir -p "$NON_REPO/state"
_reset_events
(cd "$NON_REPO" && _intake_create_workspace_branch "$NON_REPO/state" 484 "x") \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
assert_eq "not-a-git-repo → rc=2" "2" "$rc"
gnf_count="$(_event_count "intake.refused.git_unavailable")"
assert_gt "intake.refused.git_unavailable emitted" "$gnf_count" "0"

# ── Test: detached HEAD allowed with info event ──
git checkout -q main
echo extra > extra.txt
git add extra.txt
git commit -q -m extra
head_sha="$(git rev-parse HEAD)"
git checkout -q --detach "$head_sha"
_reset_events
_intake_create_workspace_branch "$STATE_DIR" 484 "from detached" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
assert_eq "detached HEAD branch creation rc=0" "0" "$rc"
det_count="$(_event_count "intake.branch.from_detached")"
assert_gt "intake.branch.from_detached emitted" "$det_count" "0"

# ── Test: branch exists on remote only → refuse ──
git checkout -q main
# Simulate remote ref existence by writing packed-refs (loose refs in
# subdirs are awkward to create reliably across git versions).
remote_sha="$(git rev-parse HEAD)"
{
    printf '# pack-refs with: peeled fully-peeled sorted\n'
    printf '%s refs/remotes/origin/zbuild/issue-484-remote-only\n' "$remote_sha"
} > "$REPO/.git/packed-refs"

_reset_events
ZBUILD_WORKSPACE_BRANCH="zbuild/issue-484-remote-only" \
    _intake_create_workspace_branch "$STATE_DIR" 484 "x" \
    > /tmp/intake-branch-test-out.$$ 2>&1
rc=$?
unset ZBUILD_WORKSPACE_BRANCH
assert_eq "branch on remote only → rc=2" "2" "$rc"
rem_count="$(_event_count "intake.refused.branch_exists_remote_only")"
assert_gt "intake.refused.branch_exists_remote_only emitted" "$rem_count" "0"

# ─── Cleanup ────────────────────────────────────────────────────────────────
cd "$REPO_ROOT" || true
rm -f /tmp/intake-branch-test-out.$$
cleanup_test_env
print_test_results
exit $((FAIL > 0))
