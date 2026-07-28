#!/usr/bin/env bash
# tests/integration/intake-worktree-isolation-test.sh
# Intake works in a per-run worktree, default-on (#888).
#
# This is the coverage that makes the feature real. Two legacy intake tests were
# pinned to ZBUILD_NO_WORKTREE=1 because they assert IN-PLACE semantics (the main
# tree's HEAD moves; main-tree strays are visible); this file asserts the opposite
# and is what proves worktree mode is not inert.
#
# SPEC-1: the branch lands in the worktree, NOT the main tree (main HEAD unmoved)
# SPEC-2: ZBUILD_REPO_ROOT is exported to the worktree so downstream stages follow
# SPEC-3: the path is persisted to intake-worktree.txt so resume can re-derive it
# SPEC-4: the worktree lives OUTSIDE the target repo
# SPEC-5: ZBUILD_NO_WORKTREE=1 restores in-place behaviour (the opt-out works)
# SPEC-6: a second run for the same run_id reuses the worktree (resume-safe)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "intake per-run worktree isolation (#888)"
setup_test_env "intake-worktree-isolation"

# Keep worktrees inside the sandbox rather than the developer's real ~/.zbuild.
export ZBUILD_RUN_ROOT="$TEST_TEMP_DIR/runroot"

# A target repo standing in for the repo being worked on.
TARGET="$TEST_TEMP_DIR/target"
mkdir -p "$TARGET"
git -C "$TARGET" init -q -b main 2>/dev/null || { git -C "$TARGET" init -q; git -C "$TARGET" checkout -q -b main 2>/dev/null; }
git -C "$TARGET" config user.email t@t; git -C "$TARGET" config user.name t
: > "$TARGET/f"; git -C "$TARGET" add -A; git -C "$TARGET" commit -qm init 2>/dev/null

# _run_intake <run_id> [extra env assignments...] — invoke the branch step only.
# Runs in a subshell so the cd/export inside intake cannot leak between cases.
_run_intake() {
    local run_id="$1"; shift
    local sd="$TEST_TEMP_DIR/state-$run_id"
    mkdir -p "$sd"
    (
        cd "$TARGET" || exit 90
        export ZBUILD_RUN_ID="$run_id"
        export ZBUILD_STATE_DIR="$sd"
        # Deterministic branch name, no gh calls.
        export ZBUILD_WORKSPACE_BRANCH="zbuild/issue-777-wt"
        while [[ $# -gt 0 ]]; do export "$1"; shift; done
        # shellcheck disable=SC1091
        source "$REPO_ROOT/plugins/agent/intake/plugin.sh" 2>/dev/null
        _intake_create_workspace_branch "$sd" 777 "worktree isolation" >/dev/null 2>&1
        printf '%s' "$?" > "$sd/rc"
        printf '%s' "${ZBUILD_REPO_ROOT:-}" > "$sd/repo_root"
    )
    printf '%s' "$sd"
}

_main_head() { git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null; }

_head_before="$(_main_head)"
SD1="$(_run_intake run-a)"
_rc1="$(cat "$SD1/rc" 2>/dev/null || echo 99)"
_wt1="$(cat "$SD1/intake-worktree.txt" 2>/dev/null || echo "")"
_rr1="$(cat "$SD1/repo_root" 2>/dev/null || echo "")"

# ── SPEC-1: branch in the worktree, main tree untouched ─────────────────────
if [[ "$_rc1" -eq 0 && -n "$_wt1" ]] \
   && [[ "$(git -C "$_wt1" rev-parse --abbrev-ref HEAD 2>/dev/null)" == "zbuild/issue-777-wt" ]] \
   && [[ "$(_main_head)" == "$_head_before" ]]; then
    assert_pass "[SPEC-1] the branch is checked out in the worktree; the main tree's HEAD is unmoved"
else
    assert_fail "[SPEC-1] branch must land in the worktree, leaving the main tree alone" \
        "rc=$_rc1 wt=$_wt1 wt_head=$(git -C "${_wt1:-/nonexistent}" rev-parse --abbrev-ref HEAD 2>&1) main_head=$(_main_head) was=$_head_before"
fi

# ── SPEC-2: ZBUILD_REPO_ROOT points downstream stages at the worktree ───────
assert_eq "[SPEC-2] ZBUILD_REPO_ROOT is exported to the worktree" "$_wt1" "$_rr1"

# ── SPEC-3: the path is persisted for resume ────────────────────────────────
if [[ -s "$SD1/intake-worktree.txt" ]]; then
    assert_pass "[SPEC-3] the worktree path is persisted to intake-worktree.txt"
else
    assert_fail "[SPEC-3] resume needs the worktree path on disk" "missing $SD1/intake-worktree.txt"
fi

# ── SPEC-4: outside the target repo ────────────────────────────────────────
if [[ -n "$_wt1" && "$_wt1" != "$TARGET"* ]]; then
    assert_pass "[SPEC-4] the worktree is outside the target repository"
else
    assert_fail "[SPEC-4] the worktree must not live inside the target repo" "wt=$_wt1 target=$TARGET"
fi

# ── SPEC-6: resume reuses the same worktree ────────────────────────────────
SD1B="$(_run_intake run-a)"
_wt1b="$(cat "$SD1B/intake-worktree.txt" 2>/dev/null || echo "")"
if [[ -n "$_wt1b" && "$_wt1b" == "$_wt1" ]]; then
    assert_pass "[SPEC-6] a second run with the same run_id reuses the worktree (resume-safe)"
else
    assert_fail "[SPEC-6] resume must reuse the run's worktree" "first=$_wt1 second=$_wt1b"
fi

# ── SPEC-5: the opt-out restores in-place behaviour ────────────────────────
# Fresh repo so the branch is not already held by run-a's worktree.
TARGET2="$TEST_TEMP_DIR/target2"
mkdir -p "$TARGET2"
git -C "$TARGET2" init -q 2>/dev/null
git -C "$TARGET2" config user.email t@t; git -C "$TARGET2" config user.name t
: > "$TARGET2/f"; git -C "$TARGET2" add -A; git -C "$TARGET2" commit -qm init 2>/dev/null
SD2="$TEST_TEMP_DIR/state-inplace"; mkdir -p "$SD2"
(
    cd "$TARGET2" || exit 90
    export ZBUILD_RUN_ID="run-b" ZBUILD_STATE_DIR="$SD2" ZBUILD_NO_WORKTREE=1
    export ZBUILD_WORKSPACE_BRANCH="zbuild/issue-778-inplace"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/plugins/agent/intake/plugin.sh" 2>/dev/null
    _intake_create_workspace_branch "$SD2" 778 "in place" >/dev/null 2>&1
    printf '%s' "$?" > "$SD2/rc"
)
_rc2="$(cat "$SD2/rc" 2>/dev/null || echo 99)"
_head2="$(git -C "$TARGET2" rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [[ "$_rc2" -eq 0 && "$_head2" == "zbuild/issue-778-inplace" && ! -f "$SD2/intake-worktree.txt" ]]; then
    assert_pass "[SPEC-5] ZBUILD_NO_WORKTREE=1 restores in-place checkout (no worktree recorded)"
else
    assert_fail "[SPEC-5] the opt-out must check out in place" \
        "rc=$_rc2 head=$_head2 wt_file=$([[ -f "$SD2/intake-worktree.txt" ]] && echo present || echo absent)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
