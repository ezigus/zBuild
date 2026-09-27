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
    local _repo="$1" _keep="${2:-}" _entry _xy _path _skip_next=0
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
            # `keep` (the pre-dispatch snapshot) stores the content as a blob,
            # so an undo can bring back uncommitted work exactly, not HEAD.
            printf '%s\t%s\n' "$_p" "$(git -C "$_repo" hash-object ${_keep:+-w} -- "$_p" 2>/dev/null || printf 'unreadable')"
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

# _wb_repo_restore <snapshot_file> <repo> <changed> — put every changed path back
# to what it was when the dispatch started: the stored blob for a path that was
# already changed, deleted if it was deleted, HEAD's copy for a path that was
# clean, and removed if it did not exist. rc 0 only when the worktree then
# matches the snapshot again — anything less is not an undo.
_wb_repo_restore() {
    local _snap="$1" _repo="$2" _todo="$3" _p _pre
    while IFS= read -r _p; do
        [[ -n "$_p" ]] || continue
        _pre="$(awk -F'\t' -v p="$_p" '$1 == p { print $2; exit }' "$_snap" 2>/dev/null)"
        if [[ "$_pre" == "deleted" ]]; then
            rm -f "$_repo/$_p" 2>/dev/null || true
        elif [[ -n "$_pre" && "$_pre" != "unreadable" ]]; then
            mkdir -p "$(dirname "$_repo/$_p")" 2>/dev/null || true
            git -C "$_repo" cat-file blob "$_pre" > "$_repo/$_p" 2>/dev/null || return 1
        elif git -C "$_repo" cat-file -e "HEAD:$_p" 2>/dev/null; then
            git -C "$_repo" checkout -q HEAD -- "$_p" 2>/dev/null || return 1
        else
            rm -rf "${_repo:?}/$_p" 2>/dev/null || true
        fi
    done <<< "$_todo"
    [[ -z "$(_wb_repo_changed "$_snap" "$_repo")" ]]
}

# _wb_repo_undo_and_judge <snap> <repo> <state_dir> <stage> <changed> <list>
# Put the worktree back to what the dispatch started with, then decide: the
# FIRST offence by this stage in this run is retried (`unusable`, via the
# per-stage undo marker the verdict reader maps), a second one — or an undo that
# could not complete — halts (`broken`). Always returns 1: the dispatch failed.
_wb_repo_undo_and_judge() {
    local _snap="$1" _repo="$2" _sd="$3" _stage="$4" _changed="$5" _list="$6"
    # Undo first, whatever happens next: the worktree goes back to exactly what
    # it held when the dispatch started. Then the FIRST offence by this stage in
    # this run is retried (`unusable`) — #1845 run 36332698182 lost 4½ hours to
    # one judge editing one test once — and a second one halts (`broken`).
    local _key _count_f _n=0 _restored=0
    _key="$(_wb_stage_key "$_stage")"
    _count_f="${_sd}/runtime/write-boundary.${_key}.offences"
    [[ -f "$_count_f" ]] && _n="$(cat "$_count_f" 2>/dev/null || echo 0)"
    [[ "$_n" =~ ^[0-9]+$ ]] || _n=0
    _n=$((_n + 1))
    printf '%s\n' "$_n" > "$_count_f" 2>/dev/null || true
    _wb_repo_restore "$_snap" "$_repo" "$_changed" && _restored=1

    if [[ $_restored -eq 1 && $_n -eq 1 ]]; then
        _ZBUILD_WB_ACTION="reverted"
        printf '%s\n' "$_list" > "${_sd}/runtime/write-boundary-reverted.${_key}" 2>/dev/null || true
        printf 'write-boundary: stage=%s changed the repository without declaring it may — put back, the stage will be retried: %s\n' \
            "$_stage" "$_list" >&2
        if [[ -n "${ZBUILD_WRITE_BOUNDARY_LOG:-}" ]]; then
            printf 'reverted stage=%s path=%s\n' "$_stage" "$_list" >> "$ZBUILD_WRITE_BOUNDARY_LOG" 2>/dev/null || true
        fi
        if declare -F emit_event >/dev/null 2>&1; then
            emit_event "stage.write_boundary.violated" "stage=${_stage}" "path=${_list}" "action=reverted" || true
        fi
        return 1
    fi
    _ZBUILD_WB_ACTION="halted"
    [[ $_restored -eq 1 ]] || _list="${_list} (could not be put back)"
    write_boundary_violation_recorded "$_sd" "$_stage" "$_list"
    return 1
}
