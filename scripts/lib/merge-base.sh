#!/usr/bin/env bash
# merge-base.sh — resolve the merge-base of HEAD against the default branch.
#
# Extracted from review/plugin.sh (_review_resolve_merge_base, #506/#896) so the
# acceptance-gate negative-control (ADR-036 #922) and review judge the SAME
# basis (full branch-vs-default-branch change set, not the per-run intake diff)
# without sourcing the review plugin (which pulls in model-route machinery).
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_MERGE_BASE_LOADED:-}" ]] && return 0
_ZBUILD_MERGE_BASE_LOADED=1

# zbuild_resolve_merge_base [<repo_root>]
# Echoes the merge-base SHA of HEAD against the default branch, or empty string
# when none resolves. Candidates: origin/main → main → HEAD~1. Fail-soft: never
# propagates git errors. With <repo_root>, runs git -C there (worktree support).
zbuild_resolve_merge_base() {
    local repo_root="${1:-}"
    local -a git=(git)
    [[ -n "$repo_root" ]] && git=(git -C "$repo_root")
    local base="" candidate
    for candidate in "origin/main" "main" "HEAD~1"; do
        if "${git[@]}" rev-parse --verify "$candidate" >/dev/null 2>&1; then
            base="$("${git[@]}" merge-base "$candidate" HEAD 2>/dev/null || true)"
            [[ -n "$base" ]] && break
        fi
    done
    printf '%s' "$base"
}
