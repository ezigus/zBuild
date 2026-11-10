#!/usr/bin/env bash
# plugins/agent/build/lib/scope.sh — what build may change (#2508, ADR-030 §8).
# Build may change any file outside the repository's test folders and none
# inside them (scripts/lib/test-paths.sh), nor any file the repository defines
# as off limits (_build_path_off_limits). It has no other file list: no scope
# block, no plan files, no request for more.
# Sourced by plugin.sh after shared libs are loaded.

[[ -n "${_ZBUILD_BUILD_SCOPE_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_SCOPE_LOADED=1
# #2460: a reply is read in whole units; loaded here too, for a caller that
# sources this file alone.
declare -F zb_reply_join_v >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/reply-units.sh" 2>/dev/null || true
declare -F zb_is_test_path >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/test-paths.sh" 2>/dev/null || true
# What the repository defines as off limits: its private-file list.
declare -F private_path_match >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/private-paths.sh" 2>/dev/null || true

# _build_path_is_scratch <path> (#1789)
# Well-known editor/VCS scratch suffixes. `sed -i.bak` and `git show HEAD:f >
# f.head` leave these behind; they are residue of an agent comparing versions of
# a file, never work in their own right. Callers apply this only to a file the
# build created: a tracked file that carries one of these suffixes is real work.
_build_path_is_scratch() {
    local _p="$1"
    [[ -z "$_p" ]] && return 1
    [[ "$_p" =~ \.(bak|orig|rej|head|tmp)$ ]] && return 0
    [[ "$_p" == *~ ]] && return 0
    return 1
}

# _build_path_off_limits <path> [repo_root] — rc 0 when build may not change the
# path (#2508, ADR-030 §8): it is outside the repository, inside .git/, or on the
# repository's own list (.zbuild/private-paths). Never the engine's defaults, and
# never by its name alone. The list is read once a run of build.
_BUILD_PRIVATE_PATTERNS=()
_BUILD_PRIVATE_LOADED=""
_build_path_off_limits() {
    local _p="${1:-}" _root="${2:-${ZBUILD_REPO_ROOT:-}}" _l
    [[ -n "$_p" ]] || return 1
    [[ "$_p" == /* || "/$_p/" == *"/../"* ]] && return 0
    [[ "$_p" == .git || "$_p" == .git/* ]] && return 0
    if [[ "$_BUILD_PRIVATE_LOADED" != "$_root" ]]; then
        _BUILD_PRIVATE_PATTERNS=()
        if [[ -n "$_root" && -f "$_root/.zbuild/private-paths" ]]; then
            while IFS= read -r _l || [[ -n "$_l" ]]; do
                _l="${_l%%#*}"; _l="${_l#"${_l%%[![:space:]]*}"}"; _l="${_l%"${_l##*[![:space:]]}"}"
                [[ -n "$_l" && "$_l" != '!'* ]] && _BUILD_PRIVATE_PATTERNS+=("$_l")
            done < "$_root/.zbuild/private-paths"
        fi
        _BUILD_PRIVATE_LOADED="$_root"
    fi
    [[ ${#_BUILD_PRIVATE_PATTERNS[@]} -gt 0 ]] && private_path_match "$_p" "${_BUILD_PRIVATE_PATTERNS[@]}"
}
