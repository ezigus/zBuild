#!/usr/bin/env bash
# scripts/lib/lint-test-helper-place.sh — a test helper lives in the test
# folders (ADR-069 §10, amendment #2510).
#
# The test folders decide who may do what: test-author owns them, build may not
# change them, a SPEC's tests are found by searching them. A helper beside
# production code escapes all three. Refused: a script under core/, scripts/ or
# plugins/, outside the repository's test folders, that a test sources and no
# production file sources or runs (`source`, `.`, `bash`, `sh`, `exec`).
#
# The test folders are the repository's own list (scripts/lib/test-paths.sh:
# .zbuild/test-paths.txt, else the engine's default). Production is every other
# file but docs/, markdown and legacy-DoNotUse/; its comments are not a use. A
# script is matched by its file name. A script production code loads by a
# computed name — a folder and a variable, `providers/$p.sh` — is production:
# every script in that folder is.
#
# Usage: bash scripts/lib/lint-test-helper-place.sh [repo_root]
# Exit:  0 clean; 1 one or more test helpers outside the test folders.
set -euo pipefail

_LTH_HERE="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
ROOT="${1:-$(cd "$_LTH_HERE/../.." && pwd)}"
# shellcheck source=./test-paths.sh
source "$_LTH_HERE/test-paths.sh"

_globs=""; zb_test_path_globs_v _globs "$ROOT"
read -ra _gl <<< "$_globs"
_in_tests() {
    local _g
    for _g in ${_gl[@]+"${_gl[@]}"}; do
        # shellcheck disable=SC2053  # the glob is meant to match
        [[ "$1" == $_g ]] && return 0
    done
    return 1
}

# Lines that may source or run a script, from every file but docs and legacy.
_RUN_RE='(^|[^[:alnum:]_./-])(source|\.|bash|sh|exec)[[:space:]]'
_SRC_RE="(^|[;&|({'\"[:space:]])(source|\.)[[:space:]]"
_NAME_RE='([[:alnum:]_.-]+\.sh)'
_DYN_RE='([[:alnum:]_.-]+)/\$\{?[[:alnum:]_]+\}?\.sh'
declare -A _by_tests=() _by_prod=() _dyn_dirs=()
while IFS= read -r _hit; do
    _f="${_hit%%:*}"; _line="${_hit#*:}"
    if _in_tests "$_f"; then
        [[ "$_line" =~ $_SRC_RE ]] || continue
        _by=_by_tests
    else
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        # An inline comment goes (assumes no path holds a space before a #).
        _line="${_line%%[[:space:]]#*}"
        [[ "$_line" =~ $_RUN_RE ]] || continue
        _by=_by_prod
        _dl="$_line"
        while [[ "$_dl" =~ $_DYN_RE ]]; do
            _dyn_dirs[${BASH_REMATCH[1]}]=1; _dl="${_dl#*"${BASH_REMATCH[0]}"}"
        done
    fi
    while [[ "$_line" =~ $_NAME_RE ]]; do
        _name="${BASH_REMATCH[1]}"; _line="${_line#*"$_name"}"
        # A file naming itself is not a use of itself.
        [[ "${_f##*/}" == "$_name" ]] && continue
        if [[ "$_by" == _by_tests ]]; then _by_tests[$_name]=1; else _by_prod[$_name]=1; fi
    done
done < <(git -C "$ROOT" grep --untracked -I -E "$_RUN_RE" -- . \
    ':!legacy-DoNotUse' ':!docs' ':!*.md' 2>/dev/null || true)

_bad=0
while IFS= read -r _f; do
    _in_tests "$_f" && continue
    _name="${_f##*/}"
    _dir="${_f%/*}"; _dir="${_dir##*/}"
    [[ -n "${_dyn_dirs[$_dir]:-}" ]] && continue
    [[ -n "${_by_tests[$_name]:-}" && -z "${_by_prod[$_name]:-}" ]] || continue
    printf '%s: is sourced only by tests; no production code sources or runs it. A test helper lives in one of the test folders (%s).\n' \
        "$_f" "$_globs" >&2
    _bad=1
done < <(git -C "$ROOT" ls-files --cached --others --exclude-standard -- \
    'core/*.sh' 'scripts/*.sh' 'plugins/*.sh')

if (( _bad )); then
    echo "lint-test-helper-place: move each into a test folder (ADR-069 §10)" >&2
    exit 1
fi
exit 0
