#!/usr/bin/env bash
# scripts/lib/judge-baseline.sh — the repository as a verdict is kept (#2574,
# ADR-072 §4): what a kept pass judged again is compared with, so it is
# refused only on a line changed since (judge_pass_flip_ok, judge-held.sh).
# Split from judge.sh (under 500 lines); judge.sh sources it.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_JUDGE_BASELINE_LOADED:-}" ]] && return 0
_ZBUILD_JUDGE_BASELINE_LOADED=1

# _judge_head_v <var> <repo> — the commit the repository is on, read by the
# shell from its .git (a worktree's too); git only when it cannot be read.
_judge_head_v() {
    local -n _jhd="$1"; local g="${2%/}/.git" l c="" ref=""
    _jhd=""
    [[ -f "$g" ]] && { IFS= read -r l < "$g" || true; [[ "$l" == "gitdir: "* ]] && g="${l#gitdir: }"; [[ "$g" == /* ]] || g="${2%/}/$g"; }
    [[ -f "$g/HEAD" ]] || return 0
    IFS= read -r l < "$g/HEAD" || true
    if [[ "$l" =~ ^[0-9a-f]{40,64}$ ]]; then _jhd="$l"; return 0; fi
    ref="${l#ref: }"
    [[ -f "$g/commondir" ]] && { IFS= read -r c < "$g/commondir" || true; [[ "$c" == /* ]] || c="$g/$c"; }
    for l in "$g/$ref" ${c:+"$c/$ref"}; do
        [[ -f "$l" ]] && { IFS= read -r _jhd < "$l" || true; [[ "$_jhd" =~ ^[0-9a-f]{40,64}$ ]] && return 0; }
    done
    _jhd="$(git -C "$2" rev-parse -q --verify HEAD 2>/dev/null)" || _jhd=""
}

# judge_keep_baseline_v <var> <repo> — what the repository holds as a verdict
# is kept, for a pass judged again later (judge_pass_flip_ok): the commit it is
# on and each file that differs from it, its content stored (the write
# boundary's snapshot, _wb_repo_snapshot keep). JSON: {"head":…,"files":{…}}.
judge_keep_baseline_v() {
    local -n _jkb="$1"; local repo="${2%/}" head="" l p v pj vj files=""
    _jkb=""
    [[ -n "$repo" && -e "$repo/.git" ]] || return 0
    _judge_head_v head "$repo"
    declare -F _wb_repo_snapshot >/dev/null 2>&1 \
        || source "$_ZB_JUDGE_DIR/../../core/pipeline/write-boundary-repo.sh" 2>/dev/null || true
    if declare -F _wb_repo_snapshot >/dev/null 2>&1; then
        while IFS=$'\t' read -r p v; do
            [[ -n "$p" ]] || continue
            _judge_json_str_v pj "$p"; _judge_json_str_v vj "$v"; files+="${files:+,}$pj:$vj"
        done < <(_wb_repo_snapshot "$repo" keep 2>/dev/null)
    fi
    _judge_json_str_v l "$head"
    _jkb="{\"head\":$l,\"files\":{$files}}"
}
