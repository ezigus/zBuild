#!/usr/bin/env bash
# tests/integration/artifact-persist-worktree-test.sh
# Artifact store/restore must work when repo_root is a LINKED WORKTREE (#888).
#
# In a linked worktree `.git` is a FILE (`gitdir: …/.git/worktrees/<name>`), not a
# directory. Two consequences the old code got wrong:
#   1. the guards tested `-d "$repo_root/.git"`, which is FALSE there, so both
#      snapshot and restore silently no-op'd inside a worktree — prior artifacts
#      would never come back and nothing would report it;
#   2. `GIT_DIR="$repo_root/.git"` resolves to the PER-WORKTREE git dir. Objects
#      are shared so blobs/trees are fine, but refs are not: the state branch
#      would land in that worktree's ref view and the next run would not find it.
#
# SPEC-1: snapshot from a worktree creates the state branch in the SHARED ref store
# SPEC-2: restore from a worktree recovers the artifacts (does not silently no-op)
# SPEC-3: a snapshot taken in the MAIN tree is restorable from a WORKTREE and vice
#         versa — the two views must agree, which is the whole point
# SPEC-4: _artifact_persist_git_dir resolves to the shared dir for both tree kinds
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "artifact persist/restore from a linked worktree (#888)"
setup_test_env "artifact-persist-worktree"

# #1921 follow-up: reserved test identity (see zb_test_issue). The literals
# here were real issue numbers; a run keyed to one writes fabricated prior
# work onto that issue's state branch.
_ZB_ID1="$(zb_test_issue)"
_ZB_ID2="$(zb_test_issue)"

# shellcheck disable=SC1091
source "$REPO_ROOT/core/state/artifact-persist.sh"

# A real repo plus a linked worktree on a second branch.
MAIN="$TEST_TEMP_DIR/main"
WT="$TEST_TEMP_DIR/wt"
mkdir -p "$MAIN"
git -C "$MAIN" init -q 2>/dev/null
git -C "$MAIN" config user.email t@t; git -C "$MAIN" config user.name t
: > "$MAIN/f"; git -C "$MAIN" add -A; git -C "$MAIN" commit -qm init 2>/dev/null
git -C "$MAIN" worktree add -q "$WT" -b work 2>/dev/null

# Sanity: the fixture is the shape under test (.git is a file in the worktree).
if [[ -f "$WT/.git" && -d "$MAIN/.git" ]]; then
    assert_pass "[fixture] linked worktree has a .git FILE; main tree has a directory"
else
    assert_fail "[fixture] expected a linked worktree with a .git file" \
        "wt=$(ls -ld "$WT/.git" 2>&1) main=$(ls -ld "$MAIN/.git" 2>&1)"
fi

# ── SPEC-4: the resolver agrees on the shared dir from both trees ────────────
# Canonicalise before comparing: on macOS /var is a symlink to /private/var, and
# the two code paths spell the same directory differently — the main tree resolves
# a relative ".git" against repo_root, while the worktree gets an absolute
# --git-common-dir. Same inode, different string; only the former would be a bug.
_canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
_gd_main="$(_canon "$(_artifact_persist_git_dir "$MAIN")")"
_gd_wt="$(_canon "$(_artifact_persist_git_dir "$WT")")"
if [[ "$_gd_main" == "$_gd_wt" && -d "$_gd_main" ]]; then
    assert_pass "[SPEC-4] _artifact_persist_git_dir resolves both trees to the same shared dir"
else
    assert_fail "[SPEC-4] both trees must resolve to one shared git dir" \
        "main=$_gd_main wt=$_gd_wt"
fi

# ── SPEC-1: snapshot FROM the worktree writes the branch to the shared store ──
SD1="$TEST_TEMP_DIR/state1"
mkdir -p "$SD1/artifacts"
printf 'from-worktree\n' > "$SD1/artifacts/plan.json"
_artifact_persist_snapshot "$SD1" $_ZB_ID1 "$WT" >/dev/null 2>&1; _snap_rc=$?
# Read the ref through the MAIN tree: if it only existed in the worktree's ref
# view, this lookup would fail — which is exactly the bug being guarded.
_ref="$(GIT_DIR="$MAIN/.git" git rev-parse -q --verify refs/heads/zbuild/state/issue-$_ZB_ID1 2>/dev/null || true)"
if [[ "$_snap_rc" -eq 0 && -n "$_ref" ]]; then
    assert_pass "[SPEC-1] snapshot from a worktree creates the state branch in the shared ref store"
else
    assert_fail "[SPEC-1] the state branch must be visible from the main tree" \
        "rc=$_snap_rc ref=[$_ref]"
fi

# ── SPEC-2: restore FROM the worktree recovers it (must not silently no-op) ───
RD1="$TEST_TEMP_DIR/restored1"
mkdir -p "$RD1"
_artifact_persist_restore $_ZB_ID1 "$RD1" "$WT" >/dev/null 2>&1; _res_rc=$?
if [[ "$_res_rc" -eq 0 ]] && grep -q "from-worktree" "$RD1/artifacts/plan.json" 2>/dev/null; then
    assert_pass "[SPEC-2] restore from a worktree recovers the artifact contents"
else
    assert_fail "[SPEC-2] restore from a worktree must not silently no-op" \
        "rc=$_res_rc tree: $(find "$RD1" -type f 2>/dev/null | tr '\n' ' ')"
fi

# ── SPEC-3: the two views agree in both directions ──────────────────────────
# main -> worktree
SD2="$TEST_TEMP_DIR/state2"; mkdir -p "$SD2/artifacts"
printf 'from-main\n' > "$SD2/artifacts/plan.json"
_artifact_persist_snapshot "$SD2" $_ZB_ID2 "$MAIN" >/dev/null 2>&1
RD2="$TEST_TEMP_DIR/restored2"; mkdir -p "$RD2"
_artifact_persist_restore $_ZB_ID2 "$RD2" "$WT" >/dev/null 2>&1
_m2w=0; grep -q "from-main" "$RD2/artifacts/plan.json" 2>/dev/null && _m2w=1
# worktree -> main  (issue 4242 was snapshotted from the worktree above)
RD3="$TEST_TEMP_DIR/restored3"; mkdir -p "$RD3"
_artifact_persist_restore $_ZB_ID1 "$RD3" "$MAIN" >/dev/null 2>&1
_w2m=0; grep -q "from-worktree" "$RD3/artifacts/plan.json" 2>/dev/null && _w2m=1
if [[ "$_m2w" -eq 1 && "$_w2m" -eq 1 ]]; then
    assert_pass "[SPEC-3] snapshots round-trip in both directions (main<->worktree)"
else
    assert_fail "[SPEC-3] main and worktree must share one view of the state branch" \
        "main->worktree=$_m2w worktree->main=$_w2m"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
