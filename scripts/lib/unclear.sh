#!/usr/bin/env bash
# scripts/lib/unclear.sh — the questions design could not settle (#2508,
# ADR-069, ADR-064 §4). Design writes a line
#   UNCLEAR: <id> | <the question> | <what it assumed>
# for a requirement it does not understand, and carries on with the assumption.
# Every report that may reach someone who can answer — the live run-status
# comment, the report of a failed run, the PR description — shows them.
#
# Sourced library: no set -euo pipefail.
[[ -n "${_ZBUILD_UNCLEAR_LOADED:-}" ]] && return 0
_ZBUILD_UNCLEAR_LOADED=1
# One question line: groups 1 id, 2 question, 3 assumed. Design's checks refuse
# an UNCLEAR line that does not match it (plugins/agent/design/lib/checks.sh).
_ZB_UNCLEAR_RE='^[[:space:]]*UNCLEAR:[[:space:]]*([^|]*[^|[:space:]])[[:space:]]*\|[[:space:]]*([^|]*[^|[:space:]])[[:space:]]*\|[[:space:]]*(.*[^[:space:]])[[:space:]]*$'

# zb_unclear_list_v <array_var> <design_md> — "<id><TAB><question><TAB><assumed>"
# per well-formed line outside a fenced block, trimmed. A line missing a part is
# not a question. Read by the shell, no fork.
zb_unclear_list_v() {
    local -n _zul="$1"; local _zul_f="${2:-}" _zul_l _zul_in=0
    _zul=()
    [[ -n "$_zul_f" && -f "$_zul_f" ]] || return 0
    while IFS= read -r _zul_l || [[ -n "$_zul_l" ]]; do
        _zul_l="${_zul_l%$'\r'}"
        if [[ "$_zul_l" =~ ^[[:space:]]*\`\`\` ]]; then _zul_in=$(( 1 - _zul_in )); continue; fi
        (( _zul_in == 0 )) && [[ "$_zul_l" =~ $_ZB_UNCLEAR_RE ]] || continue
        _zul+=("${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"$'\t'"${BASH_REMATCH[3]}")
    done < "$_zul_f"
    return 0
}

# _zb_unclear_esc_v <var> <text> — what the model wrote, safe in GitHub
# markdown: \ [ ] < > escaped, as the PR body escapes plan text.
_zb_unclear_esc_v() {
    local -n _zue="$1"; local _zue_t="$2"
    _zue_t="${_zue_t//\\/\\\\}"; _zue_t="${_zue_t//\[/\\[}"; _zue_t="${_zue_t//\]/\\]}"
    _zue_t="${_zue_t//</\\<}"; _zue_t="${_zue_t//>/\\>}"
    _zue="$_zue_t"
}

# zb_unclear_markdown_v <var> <design_md> — the questions section, or empty
# when design wrote none. No fork: the status comment renders it every tick.
zb_unclear_markdown_v() {
    local -n _zum_out="$1"; local -a _zum=(); local _zum_x _zum_id _zum_q _zum_a
    _zum_out=""
    zb_unclear_list_v _zum "${2:-}"
    [[ ${#_zum[@]} -gt 0 ]] || return 0
    _zum_out='**Questions design could not settle** (it went on with the assumption shown):'$'\n'
    for _zum_x in "${_zum[@]}"; do
        IFS=$'\t' read -r _zum_id _zum_q _zum_a <<< "$_zum_x"
        _zb_unclear_esc_v _zum_id "$_zum_id"; _zb_unclear_esc_v _zum_q "$_zum_q"; _zb_unclear_esc_v _zum_a "$_zum_a"
        _zum_out+=$'\n'"- ${_zum_id}: ${_zum_q} — assumed: ${_zum_a}"
    done
}

# zb_unclear_markdown <design_md> — the same, printed.
zb_unclear_markdown() {
    local _zm; zb_unclear_markdown_v _zm "${1:-}"
    [[ -n "$_zm" ]] && printf '%s\n' "$_zm"
    return 0
}
