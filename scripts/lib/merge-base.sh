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

_ZBUILD_MERGE_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./default-branch.sh
source "$_ZBUILD_MERGE_BASE_DIR/default-branch.sh"

# zbuild_resolve_merge_base [<repo_root>]
# Echoes the merge-base SHA of HEAD against the default branch, or EMPTY when
# none resolves. The trunk name is resolved (zbuild_resolve_default_branch:
# origin/HEAD → known remote names → local), never assumed to be "main", and
# candidates are only its remote and local refs. Fail-soft: never propagates git
# errors. With <repo_root>, runs git -C there (worktree support).
#
# #1655: there is deliberately NO HEAD~1 candidate. HEAD~1 is not "where the
# branch started", it is one commit back — on a dogfood branch that commits per
# iteration, the robot's own save from minutes earlier. It was reachable far
# more often than it looked: `rev-parse --verify` succeeds for origin/main while
# `git merge-base` returns EMPTY under a shallow clone (no visible common
# ancestor), and the old loop read that as "try the next candidate". Every gate
# then judged one commit. That cost 12h on #1848 (runs 33899707071 /
# 33944161764), where a migration committed in an earlier cycle iteration was
# invisible and reported as "not in this commit's diff". Empty is the honest
# answer, and every consumer already handles it — fail-loud
# (baseline_resolve_failed), explicit skip (no_baseline), or documented degrade.
zbuild_resolve_merge_base() {
    local repo_root="${1:-}"
    local -a git=(git)
    [[ -n "$repo_root" ]] && git=(git -C "$repo_root")
    local trunk
    trunk="$(zbuild_resolve_default_branch "${repo_root:-$PWD}")"
    [[ -z "$trunk" ]] && return 0
    local base="" candidate
    for candidate in "origin/$trunk" "$trunk"; do
        # No `rev-parse --verify` pre-check: existence was never the question.
        # merge-base itself is the computation that can fail, and an empty
        # result from a ref that DOES exist is exactly the shallow-clone case.
        base="$("${git[@]}" merge-base "$candidate" HEAD 2>/dev/null || true)"
        [[ -n "$base" ]] && break
    done
    printf '%s' "$base"
}

# zbuild_change_bundle <artifact_dir> [<repo_root>]
# Resolve the review "change bundle" as a FILE path, mirroring review/plugin.sh's
# fallback chain (#896) so review, review-lens and review-report all judge the
# SAME basis — the full-branch merge-base diff, not the per-run intake-baseline
# diff.patch (which is EMPTY on a resumed/green run or when the work was committed
# before intake — the observed #952 lens failure).
#   1. `git diff <merge-base> HEAD` written to <artifact_dir>/branch-diff.patch
#   2. the incremental build <artifact_dir>/diff.patch (echoed as-is)
#   3. when neither resolves, still echoes the diff.patch path so the caller's
#      `-s` guard yields its "(no change bundle available)" sentinel.
# Fail-soft: never propagates git errors.
zbuild_change_bundle() {
    local artifact_dir="$1" repo_root="${2:-}"
    local -a git=(git)
    [[ -n "$repo_root" ]] && git=(git -C "$repo_root")
    local base diff=""
    base="$(zbuild_resolve_merge_base "$repo_root")"
    if [[ -n "$base" ]]; then
        diff="$("${git[@]}" diff "$base" HEAD 2>/dev/null || true)"
    fi
    if [[ -n "$diff" ]]; then
        printf '%s' "$diff" > "$artifact_dir/branch-diff.patch"
        printf '%s' "$artifact_dir/branch-diff.patch"
        return 0
    fi
    printf '%s' "$artifact_dir/diff.patch"
}
