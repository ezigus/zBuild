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
