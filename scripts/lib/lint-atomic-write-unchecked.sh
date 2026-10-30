#!/usr/bin/env bash
# scripts/lib/lint-atomic-write-unchecked.sh — detect unchecked | atomic_write calls.
#
# A bare pipe to atomic_write whose exit is not checked lets a failed write
# pass silently, leaving the prior round's file looking current. This lint
# flags each violation: the same line or the immediately following executable
# line (blank and comment-only lines are skipped because comments do not reset
# PIPESTATUS in bash) must check the write exit via &&, ||, if !, or a
# PIPESTATUS capture that includes the write index.
#
# A shell-continuation line (ending with \) is checked together with its
# immediately following physical line for || or &&.
#
# Usage: bash scripts/lib/lint-atomic-write-unchecked.sh [file...]
#   No args: scans core/ plugins/ scripts/ under the repo root.
# Exit 0: no violations. Exit 1: violations emitted as file:line: text.

set -uo pipefail

_law_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_law_root="$(cd "$_law_dir/../.." && pwd)"

# Collect files to scan
_law_files=()
if [[ $# -gt 0 ]]; then
    _law_files=("$@")
else
    while IFS= read -r _law_f; do
        [[ -n "$_law_f" ]] && _law_files+=("$_law_f")
    done < <(find "$_law_root/core" "$_law_root/plugins" "$_law_root/scripts" \
        -name '*.sh' -type f 2>/dev/null | sort)
fi

_law_violations=0
# The pipe-to-write pattern, split across two variables so this script does
# not match its own patterns when scanned as part of the full codebase.
_law_pipe='|'
_law_fn='atomic_write'

for _law_file in "${_law_files[@]}"; do
    [[ -f "$_law_file" ]] || continue
    # Skip this lint script itself (it references the pattern in variable form)
    [[ "$_law_file" == */lint-atomic-write-unchecked.sh ]] && continue

    mapfile -t _law_lines < "$_law_file"
    _law_n="${#_law_lines[@]}"

    for (( _law_i=0; _law_i<_law_n; _law_i++ )); do
        _law_line="${_law_lines[$_law_i]}"
        _law_lno=$(( _law_i + 1 ))

        # Fast path: skip lines that do not contain the pipe-to-write token
        grep -qF "${_law_pipe} ${_law_fn}" <<< "$_law_line" || continue

        # 1. Same-line check: &&, ||, or if ! on the same line as the write
        grep -qE '(&&|\|\||if[[:space:]]+!)' <<< "$_law_line" && continue

        # 2. Continuation (\): current line ends with \; check next physical
        #    line for || or && (e.g. "... | atomic_write ... \ \n    || true")
        if grep -qE '\\[[:space:]]*$' <<< "$_law_line"; then
            _law_next_phys="${_law_lines[$(( _law_i + 1 ))]:-}"
            grep -qE '(\|\||&&)' <<< "$_law_next_phys" && continue
        fi

        # 3. Next executable line check: skip blank and comment-only lines
        #    (they do not reset PIPESTATUS), then look for a PIPESTATUS capture
        #    that includes the write index (e.g. PIPESTATUS[1]).
        _law_j=$(( _law_i + 1 ))
        _law_pstat=0
        while [[ "$_law_j" -lt "$_law_n" ]]; do
            _law_nxt="${_law_lines[$_law_j]}"
            # Blank or comment-only line: skip (does not reset PIPESTATUS)
            if grep -qE '^[[:space:]]*(#.*)?$' <<< "$_law_nxt"; then
                _law_j=$(( _law_j + 1 ))
                continue
            fi
            # First executable line: check for PIPESTATUS capture
            grep -qE 'PIPESTATUS\[' <<< "$_law_nxt" && _law_pstat=1
            break
        done
        [[ "$_law_pstat" -eq 1 ]] && continue

        # No exit check found: violation
        printf '%s:%d: %s\n' "$_law_file" "$_law_lno" "$_law_line"
        _law_violations=$(( _law_violations + 1 ))
    done
done

[[ "$_law_violations" -eq 0 ]]
