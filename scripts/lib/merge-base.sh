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

# zbuild_change_files_v <text_var> <fp_var> <patch_file> [<repo_root>] — what
# a judge is told of the change (#2507, ADR-072 §7): the commit the branch
# started from (the merge-base) and each file it changed since, one
# "<status>\t<path>" line, and how to read each change with git. The judge
# diffs for itself; no diff is pasted in. <fp_var> gets what the change is: the
# raw diff lines (each file's blob ids), so it changes whenever a changed file's
# content does. One git call. With no starting commit known, or no change
# committed since it, the judge is pointed at <patch_file> (the round's
# diff.patch) and the files in it.
# Sets _ZB_CHANGE_BASE to the starting commit, empty when none is known.
_ZB_CHANGE_BASE=""
zbuild_change_files_v() {
    local -n _zcfv="$1" _zcff="$2"
    _ZB_CHANGE_BASE=""
    local _zcf_patch="$3" repo_root="${4:-}"
    _zcfv="" _zcff=""
    local -a git=(git)
    [[ -n "$repo_root" ]] && git=(git -C "$repo_root")
    local _zcf_base _zcf_raw="" _zcf_l _zcf_list="" _zcf_st _zcf_p
    zbuild_resolve_merge_base_v _zcf_base "$repo_root"
    [[ -n "$_zcf_base" ]] && _zcf_raw="$("${git[@]}" diff --raw --no-abbrev --no-renames "$_zcf_base" HEAD 2>/dev/null || true)"
    # The branch's committed change, or — when it has none yet (#952: the
    # work not committed) and the round's patch has some — the patch.
    if [[ -n "$_zcf_base" && ( -n "$_zcf_raw" || -z "$_zcf_patch" || ! -s "$_zcf_patch" ) ]]; then
        _ZB_CHANGE_BASE="$_zcf_base"
        while IFS= read -r _zcf_l; do
            [[ "$_zcf_l" == :* && "$_zcf_l" == *$'\t'* ]] || continue
            _zcf_st="${_zcf_l%%$'\t'*}"; _zcf_st="${_zcf_st##* }"; _zcf_p="${_zcf_l#*$'\t'}"
            _zcf_list+="${_zcf_st:0:1}"$'\t'"$_zcf_p"$'\n'
        done <<< "$_zcf_raw"
        _zcff="$_zcf_base"$'\n'"$_zcf_raw"
        printf -v _zcfv '%s\n%s%s\n' \
            "The branch started at commit $_zcf_base. The files it changed since then (A added, M changed, D deleted):" \
            "${_zcf_list:-(none)
}" "Read each change yourself: git diff $_zcf_base HEAD -- <file> shows a file's change, git log $_zcf_base..HEAD the commits, and git show $_zcf_base:<file> the file as it was. Open the file in the repository to read it as it is now."
        return 0
    fi
    local _zcf_body=""
    [[ -n "$_zcf_patch" && -s "$_zcf_patch" ]] || { _zcfv="No commit the branch started from is known, and no patch of the change was found."; return 0; }
    IFS= read -r -d '' _zcf_body < "$_zcf_patch" || true
    while IFS= read -r _zcf_l; do
        [[ "$_zcf_l" == "diff --git a/"* ]] && _zcf_list+="${_zcf_l##* b/}"$'\n'
    done <<< "$_zcf_body"
    _zcff="$_zcf_body"
    printf -v _zcfv '%s\n%s%s\n' \
        "The change, as a patch, is in $_zcf_patch: open it to read the change. The files in it:" \
        "${_zcf_list:-(none)
}" "Open each file in the repository to read it as it is now."
}
