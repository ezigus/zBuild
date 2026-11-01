#!/usr/bin/env bash
# scripts/lib/lint-atomic-write-unchecked.sh — every `| atomic_write` checks its write (#1754).
#
# A pipe to atomic_write whose exit is not checked lets a failed write pass
# silently, leaving the prior round's file looking current. A write counts as
# checked when, after it:
#   - the same line carries `&&` or `||` (or the line is an `if !` test);
#   - the line ends in `\` and the next line carries `&&` or `||`;
#   - the next code line (blank and comment lines skipped) reads PIPESTATUS at
#     the write's place: any index but 0, which is the producer, never the write.
#
# Usage: bash scripts/lib/lint-atomic-write-unchecked.sh [file...]
#   No args: scans core/ plugins/ scripts/ under the repo root.
# Exit 0: no violations. Exit 1: violations printed as file:line: text.

set -uo pipefail

_law_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The token is split so this file does not match itself.
_law_tok='| '"atomic_write"

_law_files=()
if [[ $# -gt 0 ]]; then
    _law_files=("$@")
else
    # One grep finds the few files that hold the token; the rest are never read.
    mapfile -t _law_files < <(grep -rlF --include='*.sh' -- "$_law_tok" \
        "$_law_root/core" "$_law_root/plugins" "$_law_root/scripts" 2>/dev/null | sort)
fi

_law_re_check='(&&|\|\|)'
_law_re_cont='\\[[:space:]]*$'
_law_re_skip='^[[:space:]]*(#.*)?$'
_law_re_pstat='PIPESTATUS\[([1-9][0-9]*|-1|@|\*)\]'
_law_violations=0

for _law_file in "${_law_files[@]}"; do
    [[ -f "$_law_file" ]] || continue
    mapfile -t _law_lines < "$_law_file"
    _law_n="${#_law_lines[@]}"
    for (( _law_i = 0; _law_i < _law_n; _law_i++ )); do
        _law_line="${_law_lines[_law_i]}"
        [[ "$_law_line" == *"$_law_tok"* ]] || continue
        [[ "$_law_line" =~ ^[[:space:]]*# ]] && continue
        # A token only inside a '...' string is text, not a write.
        _law_code="$_law_line"
        while [[ "$_law_code" == *\'*\'* ]]; do
            _law_pre="${_law_code%%\'*}"
            _law_post="${_law_code#*\'}"
            _law_code="$_law_pre${_law_post#*\'}"
        done
        [[ "$_law_code" == *"$_law_tok"* ]] || continue

        _law_after="${_law_code#*"$_law_tok"}"
        [[ "$_law_after" =~ $_law_re_check ]] && continue
        [[ "$_law_code" =~ (^|[[:space:]])if[[:space:]]+! ]] && continue

        if [[ "$_law_line" =~ $_law_re_cont ]]; then
            [[ "${_law_lines[_law_i + 1]:-}" =~ $_law_re_check ]] && continue
        fi

        _law_ok=0
        for (( _law_j = _law_i + 1; _law_j < _law_n; _law_j++ )); do
            [[ "${_law_lines[_law_j]}" =~ $_law_re_skip ]] && continue
            [[ "${_law_lines[_law_j]}" =~ $_law_re_pstat ]] && _law_ok=1
            break
        done
        (( _law_ok )) && continue

        printf '%s:%d: %s\n' "$_law_file" "$(( _law_i + 1 ))" "$_law_line"
        _law_violations=$(( _law_violations + 1 ))
    done
done

(( _law_violations == 0 ))
