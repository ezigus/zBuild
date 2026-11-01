#!/usr/bin/env bash
# scripts/lib/lint-atomic-write-unchecked.sh — every `| atomic_write` checks its write (#1754).
#
# A pipe to atomic_write whose exit is not checked lets a failed write pass
# silently, leaving the prior round's file looking current. A write counts as
# checked when, after it:
#   - the same line carries `&&` or `||` (or the line is an `if !` test);
#   - the line ends in `\` and the next line starts with `&&` or `||`;
#   - the next code line (blank and comment lines skipped) reads PIPESTATUS at
#     the write's own index (its place in the pipeline) or at -1.
# Quoted text and comments are not code: a `|` or `||` inside them counts for nothing.
#
# Usage: bash scripts/lib/lint-atomic-write-unchecked.sh [file...]
#   No args: scans core/ plugins/ scripts/ under the repo root.
# Exit 0: no violations. Exit 1: violations printed as file:line: text.

set -uo pipefail

_law_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Split so this file does not match itself.
_law_fn='atomic'"_write"

_law_files=()
if [[ $# -gt 0 ]]; then
    _law_files=("$@")
else
    # One grep finds the few files that pipe to the function; the rest are never read.
    mapfile -t _law_files < <(grep -rlE --include='*.sh' -- "\\|[[:space:]]*$_law_fn" \
        "$_law_root/core" "$_law_root/plugins" "$_law_root/scripts" 2>/dev/null | sort)
fi

# _law_code <line> — sets _LAW_CODE: the line with quoted text blanked to `_`
# and any comment dropped. The quote open at the line's end is carried in
# _LAW_Q, so a '...' spanning lines (a jq filter) stays text.
_law_code() {
    local s="$1" out="" c q="$_LAW_Q" prev=" " i
    if [[ -z "$q" && "$s" != *[\'\"\\#]* ]]; then
        _LAW_CODE="$s"; return
    fi
    # A line wholly inside a multi-line string is all text.
    if [[ -n "$q" && "$s" != *"$q"* ]]; then
        _LAW_CODE=""; return
    fi
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        if [[ -n "$q" ]]; then
            if [[ "$c" == "$q" ]]; then q=""; out+="$c"; else out+="_"; fi
            if [[ "$c" == '\' && "$q" == '"' ]]; then (( i++ )); out+="_"; fi
        elif [[ "$c" == '\' ]]; then
            out+="${s:i:2}"; (( i++ ))
        elif [[ "$c" == "'" || "$c" == '"' ]]; then
            q="$c"; out+="$c"
        elif [[ "$c" == '#' && "$prev" =~ [[:space:]] ]]; then
            break
        else
            out+="$c"
        fi
        prev="$c"
    done
    _LAW_CODE="$out"; _LAW_Q="$q"
}

_law_re_tok="(^|[^|])\\|[[:space:]]*${_law_fn}([[:space:]]|\$)"
_law_re_check='(&&|\|\|)'
_law_re_lead='^[[:space:]]*(&&|\|\|)'
_law_re_cont='\\[[:space:]]*$'
_law_re_skip='^[[:space:]]*(#.*)?$'
_law_violations=0

for _law_file in "${_law_files[@]}"; do
    [[ -f "$_law_file" ]] || continue
    mapfile -t _law_lines < "$_law_file"
    _law_n="${#_law_lines[@]}"
    # Each line's code, in file order: quotes carry over, heredoc bodies are blank.
    _law_codes=(); _LAW_Q=""; _law_hd=""
    for (( _law_i = 0; _law_i < _law_n; _law_i++ )); do
        _law_line="${_law_lines[_law_i]}"
        if [[ -n "$_law_hd" ]]; then
            _law_codes[_law_i]=""
            [[ "$_law_line" =~ ^[[:space:]]*"$_law_hd"[[:space:]]*$ ]] && _law_hd=""
            continue
        fi
        _law_code "$_law_line"
        _law_codes[_law_i]="$_LAW_CODE"
        [[ -z "$_LAW_Q" && "$_law_line" =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*) ]] \
            && _law_hd="${BASH_REMATCH[1]}"
    done
    for (( _law_i = 0; _law_i < _law_n; _law_i++ )); do
        _law_line="${_law_lines[_law_i]}"
        [[ "$_law_line" == *"$_law_fn"* ]] || continue
        _law_c="${_law_codes[_law_i]}"
        [[ "$_law_c" =~ $_law_re_tok ]] || continue

        _law_before="${_law_c%%"${BASH_REMATCH[0]}"*}${BASH_REMATCH[1]}|"
        _law_after="${_law_c#*"${BASH_REMATCH[0]}"}"
        [[ "$_law_after" =~ $_law_re_check ]] && continue
        [[ "$_law_c" =~ (^|[[:space:]])if[[:space:]]+! ]] && continue
        if [[ "$_law_line" =~ $_law_re_cont ]]; then
            [[ "${_law_codes[_law_i + 1]:-}" =~ $_law_re_lead ]] && continue
        fi

        # The write's index: the pipes before it in its command, which may
        # start on earlier lines joined by a trailing `\`.
        _law_cmd="$_law_before"
        for (( _law_k = _law_i - 1; _law_k >= 0; _law_k-- )); do
            [[ "${_law_lines[_law_k]}" =~ $_law_re_cont ]] || break
            _law_cmd="${_law_codes[_law_k]} $_law_cmd"
        done
        _law_cmd="${_law_cmd//||/  }"
        _law_pipes="${_law_cmd//[^|]/}"
        _law_idx="${#_law_pipes}"

        _law_ok=0
        for (( _law_j = _law_i + 1; _law_j < _law_n; _law_j++ )); do
            [[ "${_law_codes[_law_j]}" =~ $_law_re_skip ]] && continue
            [[ "${_law_lines[_law_j]}" =~ PIPESTATUS\[($_law_idx|-1)\] ]] && _law_ok=1
            break
        done
        (( _law_ok )) && continue

        printf '%s:%d: %s\n' "$_law_file" "$(( _law_i + 1 ))" "$_law_line"
        _law_violations=$(( _law_violations + 1 ))
    done
done

(( _law_violations == 0 ))
