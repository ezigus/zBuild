#!/usr/bin/env bash
# scripts/lib/private-paths.sh — the paths no stage sees, reads or writes
# (#2379, ADR-043, ADR-058).
#
# The list is the engine's own (config/private-paths.txt), plus what the
# template (`private_paths:`) and the repository (`.zbuild/private-paths`) add.
# Additions only: a line starting with `!` is ignored, so a repository cannot
# take an engine default away.
#
# Sourced library: no `set -euo pipefail`.

[[ -n "${_ZBUILD_PRIVATE_PATHS_LOADED:-}" ]] && return 0
_ZBUILD_PRIVATE_PATHS_LOADED=1

_ZBUILD_PRIVATE_PATHS_ROOT="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd "../.." && pwd)"

# _private_paths_add <line> — one line of a list, cleaned (no comment, no
# surrounding space; a blank or `!` line is nothing), added to _ZB_PP_OUT once.
_private_paths_add() {
    local l="${1%%#*}"
    l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
    [[ -n "$l" && "$l" != '!'* ]] || return 0
    [[ $'\n'"$_ZB_PP_OUT" == *$'\n'"$l"$'\n'* ]] || _ZB_PP_OUT+="$l"$'\n'
}

# private_paths_list_v <var> <repo_root> — every private pattern, one per line,
# the engine's first, each once. Read by the shell (#2507, ADR-065 §5): every
# model call reads it twice, for its permission rules and its prompt's
# redaction. Memoised per repository and template for the life of the shell.
declare -gA _ZB_PP_MEMO=()
private_paths_list_v() {
    local -n _ppl="$1"; local repo="${2:-${ZBUILD_REPO_ROOT:-}}" tpl="${_TPL_SOURCE_FILE:-}" l inb=0
    local key="$repo|$tpl"
    if [[ -n "${_ZB_PP_MEMO[$key]+x}" ]]; then _ppl="${_ZB_PP_MEMO[$key]}"; return 0; fi
    local _ZB_PP_OUT=""
    while IFS= read -r l || [[ -n "$l" ]]; do _private_paths_add "$l"; done < "$_ZBUILD_PRIVATE_PATHS_ROOT/config/private-paths.txt"
    if [[ -n "$tpl" && -f "$tpl" ]]; then
        while IFS= read -r l || [[ -n "$l" ]]; do
            if [[ "$l" =~ ^private_paths:[[:space:]]*$ ]]; then inb=1; continue; fi
            (( inb )) || continue
            [[ "$l" =~ ^[^[:space:]#] ]] && { inb=0; continue; }
            [[ "$l" =~ ^[[:space:]]*-[[:space:]]+(.*)$ ]] || continue
            l="${BASH_REMATCH[1]//\"/}"; _private_paths_add "${l//\'/}"
        done < "$tpl"
    fi
    if [[ -n "$repo" && -f "$repo/.zbuild/private-paths" ]]; then
        while IFS= read -r l || [[ -n "$l" ]]; do _private_paths_add "$l"; done < "$repo/.zbuild/private-paths"
    fi
    _ZB_PP_MEMO[$key]="$_ZB_PP_OUT"
    _ppl="$_ZB_PP_OUT"
    return 0
}

# private_paths_list <repo_root> — the same, printed.
private_paths_list() {
    local _ppo; private_paths_list_v _ppo "${1:-${ZBUILD_REPO_ROOT:-}}"
    printf '%s' "$_ppo"
    return 0
}

# private_paths_deny_rules <repo_root> — the model-call permission rules for the
# list: reading and editing each private path is denied. A folder or a path is
# anchored at the repository root; a file name matches in any folder. (Measured
# on CLI 2.1.296: `Read(//abs/...)` refuses the Read tool and a Bash `cat`, and
# `**/*.pem` matches a file in any folder — see core/router/permissions.sh P10.)
private_paths_deny_rules() {
    local _pdr; private_paths_deny_rules_v _pdr "${1:-${ZBUILD_REPO_ROOT:-}}"
    printf '%s' "$_pdr"
}
# private_paths_deny_rules_v <var> <repo_root> — the same, one per line, into <var>.
private_paths_deny_rules_v() {
    local -n _pdrv="$1"; local repo="${2:-${ZBUILD_REPO_ROOT:-}}" p target _pdr_list
    _pdrv=""
    [[ -n "$repo" ]] || return 0
    private_paths_list_v _pdr_list "$repo"
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        case "$p" in
            */) target="$repo/$p**" ;;
            */*) target="$repo/$p" ;;
            *)  target="$repo/**/$p" ;;
        esac
        _pdrv+="Read(/$target)"$'\n'"Edit(/$target)"$'\n'
    done <<< "$_pdr_list"
}
