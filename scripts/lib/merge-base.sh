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

_ZBUILD_MERGE_BASE_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
# shellcheck source=./default-branch.sh
source "$_ZBUILD_MERGE_BASE_DIR/default-branch.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" default-branch.sh"

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
    local _zrm; zbuild_resolve_merge_base_v _zrm "${1:-}"; printf '%s' "$_zrm"
}

# zbuild_resolve_merge_base_v <var> [<repo_root>] — the same, into <var>: the
# trunk is read with no subshell, and memoised (#2482, ADR-065).
zbuild_resolve_merge_base_v() {
    local -n _zrmv="$1"; _zrmv=""
    local repo_root="${2:-}"
    local -a git=(git)
    [[ -n "$repo_root" ]] && git=(git -C "$repo_root")
    local _zrm_trunk
    zbuild_resolve_default_branch_v _zrm_trunk "${repo_root:-$PWD}"
    [[ -z "$_zrm_trunk" ]] && return 0
    local _zrm_base="" candidate
    for candidate in "origin/$_zrm_trunk" "$_zrm_trunk"; do
        # No `rev-parse --verify` pre-check: existence was never the question.
        # merge-base itself is the computation that can fail, and an empty
        # result from a ref that DOES exist is exactly the shallow-clone case.
        _zrm_base="$("${git[@]}" merge-base "$candidate" HEAD 2>/dev/null || true)"
        [[ -n "$_zrm_base" ]] && break
    done
    _zrmv="$_zrm_base"
}

# zbuild_change_bundle <artifact_dir> [<repo_root>]
# Resolve the review "change bundle" as a FILE path, mirroring review/plugin.sh's
# fallback chain (#896) so review and review-lens judge the
# SAME basis — the full-branch merge-base diff, not the per-run intake-baseline
# diff.patch (which is EMPTY on a resumed/green run or when the work was committed
# before intake — the observed #952 lens failure).
#   1. `git diff <merge-base> HEAD` written to <artifact_dir>/branch-diff.patch
#   2. the incremental build <artifact_dir>/diff.patch (echoed as-is)
#   3. when neither resolves, still echoes the diff.patch path so the caller's
#      `-s` guard yields its "(no change bundle available)" sentinel.
# Fail-soft: never propagates git errors.
zbuild_change_bundle() {
    local _zcb; zbuild_change_bundle_v _zcb "$1" "${2:-}"; printf '%s' "$_zcb"
}

# zbuild_change_bundle_v <var> <artifact_dir> [<repo_root>] — the same path,
# into <var>, with no subshell around it: issue-acceptance and every lens read
# it once a dispatch (#2482, ADR-065). The diff goes straight to its file.
zbuild_change_bundle_v() {
    local -n _zcbv="$1"
    local artifact_dir="$2" repo_root="${3:-}"
    local -a git=(git)
    [[ -n "$repo_root" ]] && git=(git -C "$repo_root")
    # Names of their own: a nameref is resolved in the callee's scope.
    local _zcb_base
    zbuild_resolve_merge_base_v _zcb_base "$repo_root"
    _zcbv="$artifact_dir/diff.patch"
    [[ -n "$_zcb_base" ]] || return 0
    "${git[@]}" diff "$_zcb_base" HEAD > "$artifact_dir/branch-diff.patch" 2>/dev/null || true
    [[ -s "$artifact_dir/branch-diff.patch" ]] && _zcbv="$artifact_dir/branch-diff.patch"
    return 0
}
