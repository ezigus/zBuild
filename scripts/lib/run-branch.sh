#!/usr/bin/env bash
# scripts/lib/run-branch.sh — keep a run's HEAD on the run's branch (#2264).
#
# Everything downstream of a stage names the run's work by its BRANCH: pr-open
# checks it out and pushes it, and the post-run step pushes refs/heads/<branch>.
# A model call can leave HEAD off that branch (a `git checkout <sha>` to try the
# baseline, killed before it switched back): every later commit then lands on
# HEAD alone, and the branch ref silently falls behind the work. #1844 run
# 37066147994 lost a whole run's commits that way.
#
# zbuild_keep_head_on_branch moves the branch forward to HEAD and puts HEAD back
# on it — only when that drops nothing (the branch is HEAD or an ancestor of it).
# It never touches the working tree or the index: HEAD's commit does not change,
# only which ref HEAD names.
#
# Sourced library: no set -euo pipefail.

# ZBUILD_HEAD_OUTCOME / ZBUILD_HEAD_WAS are read by the callers (runner,
# pr-open, merge), so shellcheck's "appears unused" (SC2034) is a false positive.
# shellcheck disable=SC2034

[[ -n "${_ZBUILD_RUN_BRANCH_LOADED:-}" ]] && return 0
_ZBUILD_RUN_BRANCH_LOADED=1

ZBUILD_HEAD_OUTCOME=""
ZBUILD_HEAD_WAS=""

# zbuild_keep_head_on_branch <repo> <branch>
# Sets ZBUILD_HEAD_OUTCOME and ZBUILD_HEAD_WAS (the ref or "detached" HEAD named):
#   on_branch   HEAD already on <branch>                         rc 0
#   reattached  <branch> moved to HEAD (or created), HEAD on it  rc 0
#   diverged    <branch> has commits HEAD lacks — nothing moved   rc 1
#   error       not a repository / no HEAD / git refused          rc 2
zbuild_keep_head_on_branch() {
    local repo="${1:-}" branch="${2:-}"
    ZBUILD_HEAD_OUTCOME="error"; ZBUILD_HEAD_WAS=""
    [[ -n "$repo" && -n "$branch" ]] || return 2
    # The common case first, in one git call: this runs at every stage end.
    local cur; cur="$(git -C "$repo" symbolic-ref -q HEAD 2>/dev/null || true)"
    ZBUILD_HEAD_WAS="${cur#refs/heads/}"; ZBUILD_HEAD_WAS="${ZBUILD_HEAD_WAS:-detached}"
    if [[ "$cur" == "refs/heads/$branch" ]]; then
        ZBUILD_HEAD_OUTCOME="on_branch"; return 0
    fi
    local head; head="$(git -C "$repo" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || return 2
    local tip; tip="$(git -C "$repo" rev-parse -q --verify "refs/heads/$branch^{commit}" 2>/dev/null || true)"
    if [[ -n "$tip" ]] && ! git -C "$repo" merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then
        ZBUILD_HEAD_OUTCOME="diverged"; return 1
    fi
    # The old tip as the expected value: refuses if the ref moved under us.
    git -C "$repo" update-ref -m "zbuild: keep HEAD on the run branch" \
        "refs/heads/$branch" "$head" ${tip:+"$tip"} 2>/dev/null || return 2
    git -C "$repo" symbolic-ref -m "zbuild: keep HEAD on the run branch" \
        HEAD "refs/heads/$branch" 2>/dev/null || return 2
    ZBUILD_HEAD_OUTCOME="reattached"
    return 0
}
