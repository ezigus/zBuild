#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/lib/numstat-format.sh — shared numstat banner formatter (#506)   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Extracted from plugins/agent/build/plugin.sh (issue #506) so the review
# plugin (and any future caller) can render a numstat-style file-change
# summary for the operator-visible stage_io banner without duplicating the
# truncation, redaction, and footer logic.
#
# Public API:
#   format_numstat <raw> <allowed_files_array_name> \
#                  [--event-prefix <name>] [--full-at <path>]
#
# Args:
#   $1 = raw numstat output (multi-line: "<adds>\t<dels>\t<path>")
#   $2 = name of an array variable holding the in-scope allowlist
#        (passed by-name so we can use a nameref); empty disables redaction
#   --event-prefix <name>   defaults to "numstat" — used as the first dotted
#                           segment of the truncation event name, e.g.
#                           "build.numstat.truncated", "review.numstat.truncated".
#   --full-at <path>        defaults to "build-summary.json" — interpolated
#                           into the truncation hint:
#                             ↪ [<N> more files · full at <path>]
#
# Stdout: formatted banner body. Per-line "+A -R path" then a
#   "total: N files, +X -Y" footer. Caps at _NUMSTAT_MAX_LINES (50) and
#   appends a truncation hint when exceeded. Emits "<prefix>.truncated" via
#   emit_event when truncated (best-effort; never fails caller).
# Returns: 0 always.
#
# Side-effect output: _NUMSTAT_FILES_COUNT is set in the CALLER's scope (the
# function is sourced, not subshelled) so the caller can read the untruncated
# file count for metadata without parsing the formatted output. Callers that
# capture via $() will not see this update — use a tempfile (see build's
# call site for the canonical pattern).
#
# Path-scope helper:
#   _numstat_path_in_scope <path> <allowed_files_array_name>
# Returns 0 (in scope) / 1 (out of scope). Prefix-match semantics mirror
# build's _build_path_in_scope (an allowed dir covers descendants).

[[ -n "${_ZBUILD_NUMSTAT_FORMAT_LOADED:-}" ]] && return 0
_ZBUILD_NUMSTAT_FORMAT_LOADED=1

_NUMSTAT_MAX_LINES=50
_NUMSTAT_FILES_COUNT=0

# _numstat_path_in_scope <path> <allowed_files_array_name>
# Prefix match: an allowed path covers itself and any descendants. Returns 0
# (in scope) or 1 (violation).
_numstat_path_in_scope() {
    local path="$1"
    local -n _ns_pis_allowed_ref="$2"
    local _ns_entry
    for _ns_entry in "${_ns_pis_allowed_ref[@]}"; do
        [[ -z "$_ns_entry" ]] && continue
        [[ "$path" == "$_ns_entry" ]] && return 0
        if [[ "$_ns_entry" == */ ]]; then
            [[ "$path" == "${_ns_entry}"* ]] && return 0
        else
            [[ "$path" == "${_ns_entry}/"* ]] && return 0
        fi
    done
    return 1
}

format_numstat() {
    local raw="$1"
    # Use a distinct nameref name to avoid the "circular name reference"
    # warning when we forward to _numstat_path_in_scope (which also uses
    # `local -n _ns_allowed_ref=...`). Bash flags same-name namerefs as circular.
    local -n _fmt_allowed_ref="$2"
    shift 2

    local event_prefix="numstat"
    local full_at="build-summary.json"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --event-prefix) event_prefix="${2:-numstat}"; shift 2 ;;
            --full-at)      full_at="${2:-build-summary.json}"; shift 2 ;;
            *) shift ;;
        esac
    done

    local total_files=0 total_add=0 total_del=0
    local shown=0
    local -a out_lines=()
    if [[ -n "$raw" ]]; then
        while IFS=$'\t' read -r adds dels path; do
            [[ -z "$path" ]] && continue
            total_files=$((total_files + 1))
            # Binary files in numstat: "-\t-\tpath".
            local add_n=0 del_n=0
            if [[ "$adds" =~ ^[0-9]+$ ]]; then add_n="$adds"; fi
            if [[ "$dels" =~ ^[0-9]+$ ]]; then del_n="$dels"; fi
            total_add=$((total_add + add_n))
            total_del=$((total_del + del_n))
            local display_path="$path"
            if [[ ${#_fmt_allowed_ref[@]} -gt 0 ]]; then
                if ! _numstat_path_in_scope "$path" _fmt_allowed_ref; then
                    display_path="<out-of-scope-context>"
                fi
            fi
            if [[ $shown -lt $_NUMSTAT_MAX_LINES ]]; then
                out_lines+=("+${adds} -${dels}  ${display_path}")
                shown=$((shown + 1))
            fi
        done <<< "$raw"
    fi
    _NUMSTAT_FILES_COUNT="$total_files"

    local line
    for line in "${out_lines[@]}"; do
        printf '%s\n' "$line"
    done
    if [[ $total_files -gt $_NUMSTAT_MAX_LINES ]]; then
        local more=$(( total_files - _NUMSTAT_MAX_LINES ))
        printf '↪ [%d more files · full at %s]\n' "$more" "$full_at"
        # Best-effort event emission; never fail caller.
        # Event name shape: "<event_prefix>.numstat.truncated" — keeps build's
        # historical "build.numstat.truncated" event stable; review will emit
        # "review.numstat.truncated" symmetrically.
        if declare -F emit_event >/dev/null 2>&1; then
            emit_event "${event_prefix}.numstat.truncated" "plugin=${event_prefix}" \
                "count=$total_files" "shown=$_NUMSTAT_MAX_LINES" \
                >/dev/null 2>&1 || true
        fi
    fi
    printf 'total: %d files, +%d -%d\n' "$total_files" "$total_add" "$total_del"
    return 0
}
