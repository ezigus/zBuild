#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild core/state/artifact-persist — durable prior-run artifact store     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Issue #1581. Generic, STAGE-AGNOSTIC persistence of a run's artifact area onto a
# SEPARATE state branch (`zbuild/state/issue-<N>`), so a later run of the same
# issue can pick prior work back up — locally or on a fresh CI runner where
# state/ is ephemeral. The store is a sibling branch that is NEVER part of the
# work branch's history, so it can never merge to main and never pollutes the PR
# diff (see #1581 design). This module knows nothing about individual stages or
# what any artifact means; it snapshots whatever files live in the artifact area.
#
# Sourced library: inherits caller's pipefail settings; do NOT add set -euo here.
# All operations are best-effort: a failure returns non-zero but never aborts the
# run (callers treat persistence as advisory).

[[ -n "${_ZBUILD_ARTIFACT_PERSIST_LOADED:-}" ]] && return 0
_ZBUILD_ARTIFACT_PERSIST_LOADED=1

# ─── _artifact_persist_branch <issue> ───────────────────────────────────────
# The state branch name for an issue. Sibling to the work branch; never merged.
_artifact_persist_branch() {
    local issue="${1:-0}"
    printf 'zbuild/state/issue-%s' "$issue"
}
# ─── _artifact_persist_git_dir <repo_root> ───────────────────────────────────
# Resolve the git dir to use for plumbing. NOT "$repo_root/.git": in a linked
# worktree that path is a FILE (`gitdir: …/.git/worktrees/<name>`), and while git
# does follow the pointer, it resolves to the PER-WORKTREE git dir. Objects are
# shared, so blobs and trees are safe — but refs are not: `update-ref
# refs/heads/zbuild/state/issue-N` would land in that worktree's ref view rather
# than the shared store, so the next run would not find the state branch.
# --git-common-dir returns the shared dir for both a main tree and a worktree.
_artifact_persist_git_dir() {
    local repo_root="${1:-}"
    local d
    d="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null)" || { printf '%s/.git' "$repo_root"; return 0; }
    # --git-common-dir may be relative to repo_root (commonly ".git").
    case "$d" in
        /*) printf '%s' "$d" ;;
        *)  printf '%s/%s' "$repo_root" "$d" ;;
    esac
}


# ─── _artifact_persist_snapshot <state_dir> <issue> [repo_root] ─────────────
# Commit the current artifact area onto the state branch WITHOUT touching the
# working tree or the real index (uses a throwaway GIT_INDEX_FILE + plumbing).
# Snapshots state/artifacts/** plus a few top-level state docs if present.
# Returns 0 on success (or clean no-op when there is nothing to snapshot), 1 on
# any git failure. Never disturbs the caller's checkout.
_artifact_persist_snapshot() {
    local state_dir="$1" issue="${2:-0}" repo_root="${3:-$(git rev-parse --show-toplevel 2>/dev/null)}"
    # Resolve the SHARED git dir before the guard uses it. The guard previously
    # tested `-d "$repo_root/.git"`, which is FALSE in a linked worktree (.git is
    # a file there), so persistence would silently no-op inside a worktree.
    local _gd=""
    [[ -n "$repo_root" ]] && _gd="$(_artifact_persist_git_dir "$repo_root")"
    [[ -z "$repo_root" || ! -d "$_gd" ]] && return 0
    local art_dir="$state_dir/artifacts"
    [[ -d "$art_dir" ]] || return 0

    local branch; branch="$(_artifact_persist_branch "$issue")"
    # A NON-existent path: git initializes a fresh index there. A pre-created
    # empty file (plain mktemp) is rejected as "index file smaller than expected".
    local tmp_index; tmp_index="$(mktemp -u "${TMPDIR:-/tmp}/zbuild-persist-idx.XXXXXX")" || return 1

    # Build a tree from the artifact files under a stable prefix (artifacts/…),
    # plus a couple of top-level state docs, in a throwaway index.
    local rc=0 added=0 f rel blob
    while IFS= read -r -d '' f; do
        rel="artifacts/${f#"$art_dir"/}"
        blob="$(GIT_DIR="$_gd" git hash-object -w "$f" 2>/dev/null)" || { rc=1; break; }
        GIT_INDEX_FILE="$tmp_index" GIT_DIR="$_gd" \
            git update-index --add --cacheinfo "100644,$blob,$rel" 2>/dev/null || { rc=1; break; }
        added=$((added + 1))
    done < <(find "$art_dir" -type f -print0 2>/dev/null)

    # Include a handful of top-level state docs when present (scope manifest etc.).
    local extra
    for extra in scope-manifest.md intake.md; do
        [[ -f "$state_dir/$extra" ]] || continue
        blob="$(GIT_DIR="$_gd" git hash-object -w "$state_dir/$extra" 2>/dev/null)" || continue
        GIT_INDEX_FILE="$tmp_index" GIT_DIR="$_gd" \
            git update-index --add --cacheinfo "100644,$blob,$extra" 2>/dev/null || true
        added=$((added + 1))
    done

    if [[ "$rc" -ne 0 || "$added" -eq 0 ]]; then
        rm -f "$tmp_index"
        [[ "$added" -eq 0 ]] && return 0 || return 1
    fi

    local tree parent commit
    tree="$(GIT_INDEX_FILE="$tmp_index" GIT_DIR="$_gd" git write-tree 2>/dev/null)" \
        || { rm -f "$tmp_index"; return 1; }
    rm -f "$tmp_index"

    parent="$(GIT_DIR="$_gd" git rev-parse -q --verify "refs/heads/$branch" 2>/dev/null || true)"
    # Skip an empty commit when the tree is identical to the current tip.
    if [[ -n "$parent" ]]; then
        local parent_tree; parent_tree="$(GIT_DIR="$_gd" git rev-parse -q --verify "$parent^{tree}" 2>/dev/null || true)"
        [[ "$parent_tree" == "$tree" ]] && return 0
    fi

    local msg="zbuild: persist artifacts for #$issue [skip ci]"
    if [[ -n "$parent" ]]; then
        commit="$(GIT_DIR="$_gd" git commit-tree "$tree" -p "$parent" -m "$msg" 2>/dev/null)" || return 1
    else
        commit="$(GIT_DIR="$_gd" git commit-tree "$tree" -m "$msg" 2>/dev/null)" || return 1
    fi
    GIT_DIR="$_gd" git update-ref "refs/heads/$branch" "$commit" 2>/dev/null || return 1
    return 0
}

# ─── _artifact_persist_restore <issue> <restored_dir> [repo_root] ───────────
# Extract the tip of the state branch into <restored_dir> (created if absent).
# Prefers a local refs/heads/<branch>; falls back to refs/remotes/origin/<branch>
# when only the fetched remote ref is present (CI). No-op (rc 0, empty dir) when
# no state branch exists. Never touches the working tree.
_artifact_persist_restore() {
    local issue="${1:-0}" restored_dir="$2" repo_root="${3:-$(git rev-parse --show-toplevel 2>/dev/null)}"
    # Resolve the SHARED git dir (see _artifact_persist_git_dir). Two reasons:
    #   1. refs must be read from the shared store, not a per-worktree view;
    #   2. the old guard tested `-d "$repo_root/.git"`, which is FALSE in a linked
    #      worktree because .git is a file there — restore would silently no-op and
    #      prior artifacts would never come back, with no error to notice.
    local _gd=""
    [[ -n "$repo_root" ]] && _gd="$(_artifact_persist_git_dir "$repo_root")"
    [[ -z "$restored_dir" ]] && return 2
    [[ -z "$repo_root" || ! -d "$_gd" ]] && return 0

    local branch; branch="$(_artifact_persist_branch "$issue")"
    local ref=""
    if GIT_DIR="$_gd" git rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
        ref="refs/heads/$branch"
    elif GIT_DIR="$_gd" git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
        ref="refs/remotes/origin/$branch"
    else
        return 0
    fi

    mkdir -p "$restored_dir" || return 1
    # git archive streams the tree; tar unpacks it, no checkout / index change.
    GIT_DIR="$_gd" git archive "$ref" 2>/dev/null | tar -x -C "$restored_dir" 2>/dev/null || return 1
    return 0
}
