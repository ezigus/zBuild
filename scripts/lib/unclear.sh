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
# #2567 (ADR-060, ADR-069 §12): design.md is text a model wrote, read in whole
# units as a reply is — a question design wrapped over lines is one line.
declare -F zb_reply_join_v >/dev/null 2>&1 \
    || source "${BASH_SOURCE[0]%/*}/reply-units.sh"
# One question line: groups 1 id, 2 question, 3 assumed. Design's checks refuse
# an UNCLEAR line that does not match it (plugins/agent/design/lib/checks.sh).
_ZB_UNCLEAR_RE='^[[:space:]]*UNCLEAR:[[:space:]]*([^|]*[^|[:space:]])[[:space:]]*\|[[:space:]]*([^|]*[^|[:space:]])[[:space:]]*\|[[:space:]]*(.*[^[:space:]])[[:space:]]*$'

# zb_unclear_lines_v <array_var> <design_md> — every UNCLEAR line outside a
# fenced block, joined whole and trimmed, well-formed or not: what the reports
# and design's form check both read. No fork: the status comment reads it on
# every tick.
zb_unclear_lines_v() {
    local -n _zun="$1"; local _zun_f="${2:-}" _zun_txt="" _zun_j="" _zun_l _zun_in=0
    _zun=()
    [[ -n "$_zun_f" && -f "$_zun_f" ]] || return 0
    IFS= read -r -d '' _zun_txt < "$_zun_f" || true
    [[ "$_zun_txt" == *UNCLEAR* ]] || return 0
    zb_reply_join_v _zun_j "${_zun_txt//$'\r'/}"
    while IFS= read -r _zun_l; do
        if [[ "$_zun_l" =~ ^[[:space:]]*\`\`\` ]]; then _zun_in=$(( 1 - _zun_in )); continue; fi
        (( _zun_in == 0 )) && [[ "$_zun_l" =~ ^[[:space:]]*UNCLEAR: ]] || continue
        _zun_l="${_zun_l#"${_zun_l%%[![:space:]]*}"}"
        _zun+=("${_zun_l%"${_zun_l##*[![:space:]]}"}")
    done <<< "$_zun_j"
    return 0
}

# zb_unclear_parse_v <var> <line> — rc 0 when <line> is a well-formed question,
# "<id><TAB><question><TAB><assumed>" into <var>. A leading "Assumed:" is set
# aside; an assumption that is nothing else is no assumption (review on #2567).
zb_unclear_parse_v() {
    local -n _zup="$1"; local _zup_id _zup_q _zup_a
    _zup=""
    [[ "$2" =~ $_ZB_UNCLEAR_RE ]] || return 1
    _zup_id="${BASH_REMATCH[1]}"; _zup_q="${BASH_REMATCH[2]}"; _zup_a="${BASH_REMATCH[3]}"
    [[ "$_zup_a" =~ ^[Aa][Ss][Ss][Uu][Mm][Ee][Dd][[:space:]]*:[[:space:]]*(.*)$ ]] && _zup_a="${BASH_REMATCH[1]}"
    [[ -n "${_zup_a//[[:space:]]/}" ]] || return 1
    _zup="$_zup_id"$'\t'"$_zup_q"$'\t'"$_zup_a"
    return 0
}

# zb_unclear_list_v <array_var> <design_md> — "<id><TAB><question><TAB><assumed>"
# per well-formed question, trimmed. A line missing a part is not a question.
zb_unclear_list_v() {
    local -n _zul="$1"; local -a _zul_all=(); local _zul_l _zul_q
    _zul=()
    zb_unclear_lines_v _zul_all "${2:-}"
    for _zul_l in ${_zul_all[@]+"${_zul_all[@]}"}; do
        zb_unclear_parse_v _zul_q "$_zul_l" && _zul+=("$_zul_q")
    done
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
