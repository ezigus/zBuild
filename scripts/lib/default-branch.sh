#!/usr/bin/env bash
# scripts/lib/default-branch.sh — the ONE default-branch (trunk) resolver (#1655).
#
# Promoted from intake's private _intake_resolve_default_branch (b6ff586, #1648)
# so merge-base.sh, intake and git-remote.sh share one implementation instead of
# three. The contract that matters is the return-empty one: a repository whose
# trunk cannot be identified must say so, because the alternative is a confident
# wrong answer. scripts/lib/git-remote.sh's zbuild_default_branch defaulted to
# the literal "main" and so could never say "I don't know" — that is precisely
# the defect this file exists to remove, which is why the never-empty helper is
# built ON this one rather than the reverse.
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_DEFAULT_BRANCH_LOADED:-}" ]] && return 0
_ZBUILD_DEFAULT_BRANCH_LOADED=1

# zbuild_resolve_default_branch [<repo>] — the remote default branch NAME, no
# "origin/" prefix. Resolution order: (1) refs/remotes/origin/HEAD stripped of
# "origin/", (2) recognized remote refs main/master/develop/trunk in order,
# (3) local refs/heads/main then refs/heads/master. Prints NOTHING (rc=0) when
# nothing resolves — callers decide what an unknown trunk means for them.
#
# Every git call is anchored with `git -C` so the repo is explicit rather than
# whatever $PWD happens to be. Defaults to $PWD, so bare calls behave as before.
#
# The prefix strip is `#origin/` (not `##*/`) on purpose: the symbolic-ref query
# is pinned to refs/remotes/origin/HEAD, so the answer is always "origin/<name>",
# and <name> may itself contain slashes (e.g. "release/v2"). Stripping to the
# last slash would truncate those to "v2".
zbuild_resolve_default_branch() {
    local repo="${1:-$PWD}"
    local ref
    ref="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
    if [[ -n "$ref" ]]; then
        printf '%s\n' "${ref#origin/}"
        return 0
    fi
    local candidate
    for candidate in main master develop trunk; do
        if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$candidate" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    for candidate in main master; do
        if git -C "$repo" show-ref --verify --quiet "refs/heads/$candidate" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 0
}
