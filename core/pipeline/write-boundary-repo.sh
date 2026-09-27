#!/usr/bin/env bash
# core/pipeline/write-boundary-repo.sh — the run's own worktree, judged by git
# content (ADR-058 C12). Sourced by core/pipeline/write-boundary.sh only.
#
# The one place a write can be attributed to a stage: ADR-059's issue lock makes
# the worktree exclusive to the run, and git records exactly what changed. A
# stage that does not declare capabilities.writes_repository must leave it as
# it found it.
#
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.

[[ -n "${_ZBUILD_WRITE_BOUNDARY_REPO_LOADED:-}" ]] && return 0
_ZBUILD_WRITE_BOUNDARY_REPO_LOADED=1

# _wb_repo_root — the run's own worktree, or nothing. In-place mode
# (ZBUILD_NO_WORKTREE=1) works in the user's checkout, which the user shares,
# so it is not the run's to judge.
_wb_repo_root() {
    [[ "${ZBUILD_NO_WORKTREE:-}" == "1" ]] && return 1
    local _r="${ZBUILD_REPO_ROOT:-}"
    [[ -n "$_r" && -d "$_r" ]] || return 1
    git -C "$_r" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    printf '%s' "$_r"
}

# _wb_repo_snapshot <repo> — one line per path that differs from HEAD (tracked
# or untracked, ignored excluded): "<path>\t<content hash|deleted>", sorted.
# Content, not status: a path whose bytes did not change during the dispatch is
# not the dispatch's write, and a HEAD move on a clean tree (intake checking out
# the work branch) leaves every line identical.
_wb_repo_snapshot() {
    local _repo="$1" _entry _xy _path _skip_next=0
    local -a _paths=()
    while IFS= read -r -d '' _entry; do
        if [[ $_skip_next -eq 1 ]]; then _paths+=("$_entry"); _skip_next=0; continue; fi
        _xy="${_entry:0:2}"; _path="${_entry:3}"
        _paths+=("$_path")
        [[ "$_xy" == R* || "$_xy" == C* ]] && _skip_next=1
    done < <(git -C "$_repo" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)
    [[ ${#_paths[@]} -gt 0 ]] || return 0
    local _p
    for _p in "${_paths[@]}"; do
        if [[ -f "$_repo/$_p" ]]; then
            printf '%s\t%s\n' "$_p" "$(git -C "$_repo" hash-object -- "$_p" 2>/dev/null || printf 'unreadable')"
        else
            printf '%s\tdeleted\n' "$_p"
        fi
    done | LC_ALL=C sort -u
}

# _wb_declares_repo_writes <plugin_dir> — rc 0 when the manifest declares
# capabilities.writes_repository: true (#2174's own fact about the stage).
_wb_declares_repo_writes() {
    local _mf="${1:-}/manifest.yaml"
    [[ -f "$_mf" ]] || return 1
    awk '
        /^[^[:space:]#]/ { inblk = ($0 ~ /^capabilities:[[:space:]]*(#.*)?$/); next }
        inblk && /^[[:space:]]+writes_repository:[[:space:]]*true[[:space:]]*(#.*)?$/ { found = 1 }
        END { exit(found ? 0 : 1) }' "$_mf" 2>/dev/null
}

# _wb_repo_changed <snapshot_file> <repo> — the paths whose content differs
# between the pre-dispatch snapshot and now, one per line, sorted. Both sides of
# `comm -3` count: a path new in `after` was written, and a path that dropped
# out of it was changed too — including a non-writer REVERTING an earlier
# stage's uncommitted work, which is touching the worktree all the same.
_wb_repo_changed() {
    local _snap="$1" _repo="$2" _after
    _after="$(_wb_repo_snapshot "$_repo")"
    LC_ALL=C comm -3 "$_snap" <(printf '%s\n' "$_after" | grep -v '^$' || true) 2>/dev/null \
        | sed 's/^\t//' | cut -f1 | LC_ALL=C sort -u | grep -v '^$' || true
}

# _wb_repo_changed_list <repo> <paths> — absolute, comma-separated, capped at 20
# so a stage that rewrote the tree does not produce an unbounded marker.
_wb_repo_changed_list() {
    local _repo="$1" _changed="$2" _p _out="" _n=0 _total=0
    while IFS= read -r _p; do [[ -n "$_p" ]] && _total=$((_total + 1)); done <<< "$_changed"
    while IFS= read -r _p; do
        [[ -n "$_p" ]] || continue
        _n=$((_n + 1))
        [[ $_n -gt 20 ]] && { _out+=" (+$((_total - 20)) more)"; break; }
        _out+="${_out:+, }$_repo/$_p"
    done <<< "$_changed"
    printf '%s' "$_out"
}
