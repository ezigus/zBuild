#!/usr/bin/env bash
# scripts/lib/test-paths.sh — which paths are tests: the repository's test
# folders, read as data (ADR-069 §10). The engine's config/test-paths.txt is the
# default; a repository's own .zbuild/test-paths.txt replaces it.
#
# Sourced library: no set -euo pipefail.
[[ -n "${_ZBUILD_TEST_PATHS_LOADED:-}" ]] && return 0
_ZBUILD_TEST_PATHS_LOADED=1
# Beside this library when it sits in an engine tree; a library loaded from
# elsewhere (ZBUILD_CONTRACT_LIB_DIR) finds the list under the engine's root.
_ZBUILD_TEST_PATHS_DEFAULT="$(cd "${BASH_SOURCE[0]%/*}/../../config" 2>/dev/null && pwd)/test-paths.txt"

# zb_test_path_globs_v <var> [repo_root] — the globs, space-separated.
zb_test_path_globs_v() {
    local -n _tpg="$1"; local _root="${2:-${ZBUILD_REPO_ROOT:-}}" _f _l
    _f="$_ZBUILD_TEST_PATHS_DEFAULT"
    [[ -f "$_f" || -z "${_ZBUILD_ROOT:-}" ]] || _f="$_ZBUILD_ROOT/config/test-paths.txt"
    [[ -n "$_root" && -f "$_root/.zbuild/test-paths.txt" ]] && _f="$_root/.zbuild/test-paths.txt"
    _tpg=""
    [[ -f "$_f" ]] || return 0
    while IFS= read -r _l || [[ -n "$_l" ]]; do
        _l="${_l%%#*}"; _l="${_l//[[:space:]]/}"
        [[ -n "$_l" ]] && _tpg+="${_tpg:+ }$_l"
    done < "$_f"
}

# zb_is_test_path <path> [repo_root] — rc 0 when the path is in a test folder.
zb_is_test_path() {
    local _p="${1:-}" _globs _g
    [[ -n "$_p" ]] || return 1
    zb_test_path_globs_v _globs "${2:-}"
    # read -a, not an unquoted expansion: that would expand each glob against
    # the files in the current directory.
    local -a _gl=()
    read -ra _gl <<< "$_globs"
    for _g in ${_gl[@]+"${_gl[@]}"}; do
        # shellcheck disable=SC2053  # the glob is meant to match
        [[ "$_p" == $_g ]] && return 0
    done
    return 1
}

# _zb_test_globs_match <path> <glob...> — rc 0 when the path matches a glob.
_zb_test_globs_match() {
    local _p="$1" _g; shift
    for _g in "$@"; do
        # shellcheck disable=SC2053  # the glob is meant to match
        [[ "$_p" == $_g ]] && return 0
    done
    return 1
}

# zb_test_folder_files_v <array_var> [repo_root] — every file in the test
# folders, committed or not (ignored files left out), as paths from the root
# (#2508). One git fork.
zb_test_folder_files_v() {
    local -n _ztf_out="$1"; local _root="${2:-${ZBUILD_REPO_ROOT:-$PWD}}" _globs _f
    local -a _gl=()
    _ztf_out=()
    zb_test_path_globs_v _globs "$_root"
    read -ra _gl <<< "$_globs"
    [[ ${#_gl[@]} -gt 0 ]] || return 0
    while IFS= read -r -d '' _f; do
        [[ -f "$_root/$_f" ]] && _zb_test_globs_match "$_f" "${_gl[@]}" && _ztf_out+=("$_f")
    done < <(git -C "$_root" ls-files -co --exclude-standard -z 2>/dev/null)
    return 0
}

# zb_test_folder_changes_v <array_var> [repo_root] — each file in the test
# folders that differs from HEAD: changed, added, deleted or new (#2508). The
# test author commits these; build may change none of them. One git fork.
zb_test_folder_changes_v() {
    local -n _ztc_out="$1"; local _root="${2:-${ZBUILD_REPO_ROOT:-$PWD}}" _globs _e _p
    local -a _gl=()
    _ztc_out=()
    zb_test_path_globs_v _globs "$_root"
    read -ra _gl <<< "$_globs"
    [[ ${#_gl[@]} -gt 0 ]] || return 0
    local _skip=0
    while IFS= read -r -d '' _e; do
        # A rename's second entry is its old path: it is a change too, counted
        # when it lies in the test folders (the add stages both sides).
        if (( _skip )); then _skip=0; _zb_test_globs_match "$_e" "${_gl[@]}" && _ztc_out+=("$_e"); continue; fi
        [[ "$_e" == R* || "$_e" == C* ]] && _skip=1
        _p="${_e:3}"
        _zb_test_globs_match "$_p" "${_gl[@]}" && _ztc_out+=("$_p")
    done < <(git -C "$_root" status --porcelain -z --untracked-files=all 2>/dev/null)
    return 0
}
