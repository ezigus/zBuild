#!/usr/bin/env bash
# scripts/lib/git-remote.sh — resilient remote-branch push reconcile (Issue PR).
#
# The pr-open / merge stages used to run `git push -u origin <b> 2>/dev/null`,
# which hides git's stderr and hard-fails whenever origin already has the branch
# (re-run, resumed pipeline) or has diverged. zbuild_push_reconcile inspects the
# remote tip and pushes safely: absent → push -u, up-to-date → skip,
# fast-forward → plain push, diverged → --force-with-lease (feature branches
# only; NEVER the default branch). Real stderr is surfaced in
# ZBUILD_PUSH_RECONCILE_ERR so callers can put it in pr-result.json .reason.
#
# No new events, no model calls (preserves the pr stage's T0 contract).
# Sourced library: no set -euo pipefail.

# ZBUILD_PUSH_RECONCILE_ERR is read by pr-open / merge plugins that source this
# lib, so shellcheck's "appears unused" (SC2034) is a false positive here.
# shellcheck disable=SC2034

[[ -n "${_ZBUILD_GIT_REMOTE_LOADED:-}" ]] && return 0
_ZBUILD_GIT_REMOTE_LOADED=1

# Captured stderr / failure reason (empty on success). Callers read this.
ZBUILD_PUSH_RECONCILE_ERR=""

# _grm_push <git-push-args...> — run `git push`, capturing stderr into
# ZBUILD_PUSH_RECONCILE_ERR (stops the historic 2>/dev/null discard). Returns
# git's own exit code.
_grm_push() {
    local _err _rc
    _err="$(git push "$@" 2>&1 >/dev/null)"; _rc=$?
    [[ $_rc -ne 0 ]] && ZBUILD_PUSH_RECONCILE_ERR="$_err"
    return $_rc
}

# zbuild_default_branch — best-effort remote default branch name (no origin/
# prefix). Falls back to init.defaultBranch, then "main". The reconcile guard
# also hardcodes main/master regardless of what this resolves.
zbuild_default_branch() {
    local ref
    ref="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
    if [[ -n "$ref" ]]; then
        printf '%s\n' "${ref#origin/}"
        return 0
    fi
    ref="$(git config init.defaultBranch 2>/dev/null)"
    printf '%s\n' "${ref:-main}"
}

# zbuild_push_reconcile <branch> — reconcile origin/<branch> with local HEAD,
# then ensure it is pushed. Return codes:
#   0  success (pushed / fast-forwarded / force-with-lease / already-up-to-date)
#   2  bad input (empty branch)
#   3  genuine failure (stderr in ZBUILD_PUSH_RECONCILE_ERR)
#   4  refused: would force-push the default branch
zbuild_push_reconcile() {
    local branch="${1:-}"
    ZBUILD_PUSH_RECONCILE_ERR=""

    if [[ -z "$branch" ]]; then
        ZBUILD_PUSH_RECONCILE_ERR="empty branch"
        return 2
    fi

    local remote_ls ls_rc
    remote_ls="$(git ls-remote --heads origin "$branch" 2>&1)"; ls_rc=$?
    if [[ $ls_rc -ne 0 ]]; then
        ZBUILD_PUSH_RECONCILE_ERR="ls-remote failed: $remote_ls"
        return 3
    fi

    # ── ABSENT: remote has no such branch → first push ───────────────────────
    if [[ -z "$remote_ls" ]]; then
        _grm_push -u origin "$branch" && return 0
        return 3
    fi

    # ── PRESENT: reconcile against the remote tip ────────────────────────────
    local remote_sha local_sha
    remote_sha="${remote_ls%%[[:space:]]*}"
    local_sha="$(git rev-parse HEAD 2>/dev/null)"

    # Bring the origin tip object local so ancestry / lease checks are accurate.
    git fetch origin "$branch" >/dev/null 2>&1 || true

    # Never blind-force: if we can't resolve the tip object, fail loud.
    if ! git cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
        ZBUILD_PUSH_RECONCILE_ERR="cannot resolve origin tip ${remote_sha} (fetch failed)"
        return 3
    fi

    # ── UP-TO-DATE: nothing to push ──────────────────────────────────────────
    if [[ "$remote_sha" == "$local_sha" ]]; then
        git branch --set-upstream-to="origin/${branch}" "$branch" >/dev/null 2>&1 || true
        return 0
    fi

    # ── FAST-FORWARD: remote tip is an ancestor of HEAD ──────────────────────
    if git merge-base --is-ancestor "$remote_sha" HEAD 2>/dev/null; then
        _grm_push origin "$branch" && return 0
        return 3
    fi

    # ── DIVERGED: safe force, but NEVER the default branch ───────────────────
    local def; def="$(zbuild_default_branch)"
    if [[ "$branch" == "$def" || "$branch" == "main" || "$branch" == "master" ]]; then
        ZBUILD_PUSH_RECONCILE_ERR="refusing to force-push default branch '${branch}'"
        return 4
    fi

    # --force-with-lease pinned to the sha we read: refuses if origin advanced.
    _grm_push --force-with-lease="${branch}:${remote_sha}" origin "$branch" && return 0
    return 3
}
