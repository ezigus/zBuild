#!/usr/bin/env bash
# scripts/lib/call-graph.sh — bash call-graph producer for changed-surface evidence.
#
# Exports: call_graph_produce <diff_patch> <repo_root> <out_file>
# Sourced library: does NOT set errexit/pipefail (inherits caller's env).

[[ -n "${_ZBUILD_CALL_GRAPH_LOADED:-}" ]] && return 0
_ZBUILD_CALL_GRAPH_LOADED=1

# ─── call_graph_produce <diff_patch> <repo_root> <out_file> ─────────────────
# Extracts bash function definitions from added lines in the diff (pattern:
# ^+<optional-space><name>()). Greps repo for callers; collects callees from
# added lines in the diff body. Emits JSON artifact. Degrades to empty
# changed_surface on a missing or functionless diff. Always returns 0.
call_graph_produce() {
    local _cg_diff="${1:-}" _cg_root="${2:-.}" _cg_out="${3:-/dev/null}"
    local _cg_gfor
    _cg_gfor="$(basename "${_cg_diff:-unknown.patch}")"

    # Write the empty/fallback artifact up front so the caller always has a file.
    printf '{"schema_version":1,"generated_for":"%s","changed_surface":[]}\n' \
        "$_cg_gfor" > "$_cg_out" 2>/dev/null || true

    [[ -z "$_cg_diff" || ! -s "$_cg_diff" ]] && return 0

    # Pass 1: parse diff for function definitions in added lines of .sh files.
    local -a _cg_funcs=() _cg_files=()
    local _cg_cursh=""
    while IFS= read -r _cg_line; do
        if [[ "$_cg_line" =~ ^diff[[:space:]]--git[[:space:]][ab]/.+[[:space:]][ab]/(.+\.sh)$ ]]; then
            _cg_cursh="${BASH_REMATCH[1]}"
        elif [[ "$_cg_line" =~ ^diff[[:space:]]--git ]]; then
            _cg_cursh=""
        elif [[ "$_cg_line" =~ ^(\+\+\+|---) ]]; then
            : # skip diff header lines
        elif [[ -n "$_cg_cursh" && \
                "$_cg_line" =~ ^\+[[:space:]]*([a-z_][a-z_0-9]*)[[:space:]]*\(\) ]]; then
            _cg_funcs+=("${BASH_REMATCH[1]}")
            _cg_files+=("$_cg_cursh")
        fi
    done < "$_cg_diff"

    [[ "${#_cg_funcs[@]}" -eq 0 ]] && return 0

    # Pass 2: build changed_surface JSON entries.
    local _cg_surface="[]"
    local _cg_i
    for (( _cg_i=0; _cg_i<${#_cg_funcs[@]}; _cg_i++ )); do
        local _fn="${_cg_funcs[$_cg_i]}" _ff="${_cg_files[$_cg_i]}"

        # Callers: repo-wide grep for invocations (excludes definition lines).
        local _callers="[]"
        _callers="$(
            { grep -rn --include="*.sh" -w "$_fn" "$_cg_root" 2>/dev/null || true; } \
            | { grep -vE "${_fn}[[:space:]]*\(\)" 2>/dev/null || true; } \
            | { grep -v "^Binary" 2>/dev/null || true; } \
            | awk -F: '{printf "%s:%s\n",$1,$2}' \
            | head -10 \
            | jq -Rsc 'split("\n") | map(select(length>0))' 2>/dev/null
        )" || _callers="[]"
        [[ -z "$_callers" ]] && _callers="[]"

        # Callees: distinct identifiers on added lines in the diff.
        local _callees="[]"
        _callees="$(
            { grep -E '^\+[^+]' "$_cg_diff" 2>/dev/null || true; } \
            | { grep -oE '\b[a-z_][a-z_0-9]{2,}\b' 2>/dev/null || true; } \
            | { grep -v "^${_fn}$" 2>/dev/null || true; } \
            | sort -u | head -10 \
            | jq -Rsc 'split("\n") | map(select(length>0))' 2>/dev/null
        )" || _callees="[]"
        [[ -z "$_callees" ]] && _callees="[]"

        _cg_surface="$(
            printf '%s' "$_cg_surface" \
            | jq -c --arg fn "$_fn" --arg ff "$_ff" \
                --argjson ca "$_callers" --argjson ce "$_callees" \
                '. + [{function:$fn, file:$ff, callers:$ca, callees:$ce}]' 2>/dev/null
        )" || _cg_surface="[]"
    done

    jq -nc \
        --argjson s "$_cg_surface" \
        --arg gf "$_cg_gfor" \
        '{schema_version:1, generated_for:$gf, changed_surface:$s}' \
        > "$_cg_out" 2>/dev/null || true

    return 0
}
