#!/usr/bin/env bash
# scripts/lib/unclear-report.sh — the reports' side of scripts/lib/unclear.sh
# (#2571, ADR-069 §12, ADR-064 §4): a stage's questions in its result, written
# and read back with no fork, and the questions section every report shows —
# the run-status comment on every tick, the failed run's report, the PR body.
# Sourced by unclear.sh; no set -euo pipefail. Nothing here forks.
[[ -n "${_ZBUILD_UNCLEAR_REPORT_LOADED:-}" ]] && return 0
_ZBUILD_UNCLEAR_REPORT_LOADED=1
# shellcheck source=./json-text.sh
source "${BASH_SOURCE[0]%/*}/json-text.sh"

# zb_unclear_result_json_v <var> <array_name> [note_var] — the lines of
# <array_name> as a JSON array of strings, for a stage's result: data.unclear;
# at most ZB_UNCLEAR_MAX of them, [note_var] saying how many were left out.
# Control characters become spaces, so zb_unclear_result_lines_v reads it back whole.
zb_unclear_result_json_v() {
    local -n _zrj="$1" _zrj_a="$2"; local _zrj_l _zrj_o="" _zrj_sep="" _zrj_nt=""
    local -a _zrj_c=(${_zrj_a[@]+"${_zrj_a[@]}"})
    zb_unclear_cap_v _zrj_c _zrj_nt
    if [[ -n "${3:-}" ]]; then local -n _zrj_n="$3"; _zrj_n="$_zrj_nt"; fi
    for _zrj_l in ${_zrj_c[@]+"${_zrj_c[@]}"}; do
        _zb_unclear_json_str_v _zrj_l "$_zrj_l"; _zrj_o+="$_zrj_sep$_zrj_l"; _zrj_sep=","
    done
    _zrj="[$_zrj_o]"
}

# _zb_unclear_json_str_v <var> <text> — <text> as a JSON string, quoted, on
# one line: control characters become spaces.
_zb_unclear_json_str_v() { zb_json_str_v "$1" "${2//[[:cntrl:]]/ }"; }

# zb_unclear_dropped_json_v <var> <dropped_array_name> [carried] — the
# questions a check retired, for a stage's result: data.unclear_dropped, so no
# retirement is silent (#2571 review). Each entry of <dropped_array_name> is as
# zb_unclear_answers_v drops it, "<id> TAB <answered|not needed> TAB <why> TAB
# <quote>", with an optional fifth field, the question as carried; else the
# question is found by its id in [carried] (lines, one per line). The JSON: an
# array of {id, verdict, why, quote, question}, at most ZB_UNCLEAR_MAX.
zb_unclear_dropped_json_v() {
    local -n _zdj="$1" _zdj_a="$2"; local _zdj_x _zdj_l _zdj_p _zdj_o="" _zdj_sep="" _zdj_k _zdj_v _zdj_s
    local -A _zdj_q=(); local -a _zdj_c=(${_zdj_a[@]+"${_zdj_a[@]}"})
    while IFS= read -r _zdj_l; do
        zb_unclear_parse_v _zdj_p "$_zdj_l" || continue
        [[ -n "${_zdj_q[${_zdj_p%%$'\t'*}]+x}" ]] || _zdj_q["${_zdj_p%%$'\t'*}"]="$_zdj_l"
    done <<< "${3:-}"
    zb_unclear_cap_v _zdj_c _zdj_s
    for _zdj_x in ${_zdj_c[@]+"${_zdj_c[@]}"}; do
        local -a _zdj_f=(); _zb_unclear_split_v _zdj_f "$_zdj_x"
        [[ -n "${_zdj_f[4]:-}" ]] || _zdj_f[4]="${_zdj_f[0]:+${_zdj_q[${_zdj_f[0]}]:-}}"
        _zdj_s=""; _zdj_k=0
        for _zdj_v in id verdict why quote question; do
            _zb_unclear_json_str_v _zdj_l "${_zdj_f[_zdj_k]:-}"
            _zdj_s+="${_zdj_s:+,}\"$_zdj_v\":$_zdj_l"; _zdj_k=$(( _zdj_k + 1 ))
        done
        _zdj_o+="$_zdj_sep{$_zdj_s}"; _zdj_sep=","
    done
    _zdj="[$_zdj_o]"
}

# _zb_unclear_read_v <var> <file> — the file's text, rc 1 when it is over
# _ZB_UNCLEAR_FILE_MAX characters (then not read further) or empty.
_zb_unclear_read_v() {
    local -n _zrd="$1"
    _zrd=""
    [[ -n "${2:-}" && -s "$2" ]] || return 1
    IFS= read -r -N "$(( _ZB_UNCLEAR_FILE_MAX + 1 ))" _zrd < "$2" || true
    (( ${#_zrd} <= _ZB_UNCLEAR_FILE_MAX )) || { _zrd=""; return 1; }
    return 0
}

# zb_unclear_result_lines_v <array_var> <result_json> — the lines of the
# result's "unclear" array, with no fork: each string read back
# (zb_json_unescape_v) on one line. Bounded
# (#2571 review): at most _ZB_UNCLEAR_READ_MAX lines of _ZB_UNCLEAR_LINE_MAX
# characters, read from a window after the key, never the rest copied per line.
zb_unclear_result_lines_v() {
    local -n _zrl="$1"; local _zrl_t="" _zrl_s _zrl_n=0 _zrl_re='"unclear"[[:space:]]*:[[:space:]]*\['
    local _zrl_str='^[[:space:],]*"'"$ZB_JSON_STR_RE"'"'
    _zrl=()
    _zb_unclear_read_v _zrl_t "${2:-}" || return 0
    [[ "$_zrl_t" =~ $_zrl_re ]] || return 0
    _zrl_t="${_zrl_t#*"${BASH_REMATCH[0]}"}"
    _zrl_t="${_zrl_t:0:$(( _ZB_UNCLEAR_READ_MAX * (_ZB_UNCLEAR_LINE_MAX * 2 + 100) ))}"
    while (( _zrl_n < _ZB_UNCLEAR_READ_MAX )) && [[ "$_zrl_t" =~ $_zrl_str ]]; do
        _zrl_t="${_zrl_t:${#BASH_REMATCH[0]}}"; _zrl_n=$(( _zrl_n + 1 ))
        _zb_unclear_unesc_v _zrl_s "${BASH_REMATCH[1]}"
        _zrl+=("$_zrl_s")
    done
    return 0
}

# _zb_unclear_unesc_v <var> <json_string_body> — read back on one line: a
# control character a space; at most _ZB_UNCLEAR_LINE_MAX characters.
_zb_unclear_unesc_v() {
    local -n _zue_o="$1"; local _zue_s
    zb_json_unescape_v _zue_s "$2"; _zue_s="${_zue_s//[[:cntrl:]]/ }"
    _zue_o="${_zue_s:0:_ZB_UNCLEAR_LINE_MAX}"
}

# zb_unclear_dropped_lines_v <array_var> <result_json> — each retired question
# of the result's data.unclear_dropped, "<id> TAB <verdict> TAB <why> TAB
# <quote> TAB <question>", with no fork and bounded as zb_unclear_result_lines_v
# is; the objects' keys in any order, a field that is not a string left empty.
zb_unclear_dropped_lines_v() {
    local -n _zdl="$1"; local _zdl_t="" _zdl_n=0 _zdl_v _zdl_re='"unclear_dropped"[[:space:]]*:[[:space:]]*\['
    local _zdl_kv='^[[:space:],]*"([A-Za-z_]+)"[[:space:]]*:[[:space:]]*("'"$ZB_JSON_STR_RE"'"|null|true|false|-?[0-9][0-9.eE+-]*)'
    local -A _zdl_o=()
    _zdl=()
    _zb_unclear_read_v _zdl_t "${2:-}" || return 0
    [[ "$_zdl_t" =~ $_zdl_re ]] || return 0
    _zdl_t="${_zdl_t#*"${BASH_REMATCH[0]}"}"
    _zdl_t="${_zdl_t:0:$(( _ZB_UNCLEAR_READ_MAX * (_ZB_UNCLEAR_LINE_MAX * 6 + 200) ))}"
    while (( _zdl_n < _ZB_UNCLEAR_READ_MAX )) && [[ "$_zdl_t" =~ ^[[:space:],]*\{ ]]; do
        _zdl_t="${_zdl_t:${#BASH_REMATCH[0]}}"; _zdl_o=(); _zdl_n=$(( _zdl_n + 1 ))
        while [[ "$_zdl_t" =~ $_zdl_kv ]]; do
            _zdl_t="${_zdl_t:${#BASH_REMATCH[0]}}"
            [[ "${BASH_REMATCH[2]}" == \"* ]] || continue
            _zb_unclear_unesc_v _zdl_v "${BASH_REMATCH[3]}"; _zdl_o["${BASH_REMATCH[1]}"]="${_zdl_v//$'\t'/ }"
        done
        [[ "$_zdl_t" =~ ^[[:space:]]*\} ]] || break
        _zdl_t="${_zdl_t:${#BASH_REMATCH[0]}}"
        _zdl+=("${_zdl_o[id]:-}"$'\t'"${_zdl_o[verdict]:-}"$'\t'"${_zdl_o[why]:-}"$'\t'"${_zdl_o[quote]:-}"$'\t'"${_zdl_o[question]:-}")
    done
    return 0
}

# zb_unclear_result_ok <file> [run_start_marker] — rc 0 when <file> is a stage
# result (<stage>-result.json or <stage>-verdict.json) of at most
# _ZB_UNCLEAR_FILE_MAX characters that carries questions, open or retired, and
# is newer than the marker when there is one: a result an earlier run left, even
# one with the run start's own time, is not this run's.
zb_unclear_result_ok() {
    local _zro_t
    [[ "${1:-}" == *-result.json || "${1:-}" == *-verdict.json ]] || return 1
    [[ -n "${2:-}" && -e "$2" && ! "$1" -nt "$2" ]] && return 1
    _zb_unclear_read_v _zro_t "$1" || return 1
    [[ "$_zro_t" == *'"unclear"'* || "$_zro_t" == *'"unclear_dropped"'* || "$_zro_t" == *'"suspected"'* ]]
}

# zb_unclear_results_in_v <array_var> <dir> [run_start_marker] — each stage
# result in <dir> that zb_unclear_result_ok takes.
zb_unclear_results_in_v() {
    local -n _zri="$1"; local _zri_f
    _zri=()
    [[ -n "${2:-}" && -d "$2" ]] || return 0
    for _zri_f in "$2"/*-result.json "$2"/*-verdict.json; do
        zb_unclear_result_ok "$_zri_f" "${3:-}" && _zri+=("$_zri_f")
    done
    return 0
}

# _zb_unclear_esc_v <var> <text> — what the model wrote, inert in GitHub
# markdown: \ [ ] < > ` * escaped, as the PR body escapes plan text; an @ and a
# # before a digit, and ://, broken by a zero-width space, so it mentions no
# one, links no issue and makes no link (#2571 review).
_ZB_UNCLEAR_ZWSP=$'\xe2\x80\x8b'
_zb_unclear_esc_v() {
    local -n _zue="$1"; local _zue_t="$2" _zue_d
    _zue_t="${_zue_t//\\/\\\\}"; _zue_t="${_zue_t//\[/\\[}"; _zue_t="${_zue_t//\]/\\]}"
    _zue_t="${_zue_t//</\\<}"; _zue_t="${_zue_t//>/\\>}"
    _zue_t="${_zue_t//\`/\\\`}"; _zue_t="${_zue_t//\*/\\*}"
    _zue_t="${_zue_t//@/@$_ZB_UNCLEAR_ZWSP}"; _zue_t="${_zue_t//:\/\//:$_ZB_UNCLEAR_ZWSP//}"
    for _zue_d in 0 1 2 3 4 5 6 7 8 9; do _zue_t="${_zue_t//\#$_zue_d/#$_ZB_UNCLEAR_ZWSP$_zue_d}"; done
    _zue="$_zue_t"
}

# _zb_unclear_section_v <var> <stage> <array_name> — one stage's questions
# (lines as written), or empty when none is readable.
_zb_unclear_section_v() {
    local -n _zus="$1" _zus_a="$3"; local _zus_l _zus_p _zus_id _zus_q _zus_r _zus_as _zus_x=""
    _zus=""
    for _zus_l in ${_zus_a[@]+"${_zus_a[@]}"}; do
        zb_unclear_parse_v _zus_p "$_zus_l" || continue
        local -a _zus_f=(); _zb_unclear_split_v _zus_f "$_zus_p"
        _zus_id="${_zus_f[0]}"; _zus_q="${_zus_f[1]}"; _zus_r="${_zus_f[2]}"; _zus_as="${_zus_f[3]}"
        _zb_unclear_esc_v _zus_id "$_zus_id"; _zb_unclear_esc_v _zus_q "$_zus_q"
        _zb_unclear_esc_v _zus_r "$_zus_r"; _zb_unclear_esc_v _zus_as "$_zus_as"
        _zus_x+=$'\n'"- ${_zus_id}: ${_zus_q:+\"$_zus_q\" — }${_zus_r} — assumed: ${_zus_as}"
    done
    [[ -n "$_zus_x" ]] || return 0
    _zus="**Questions $2 could not settle** (it went on with the assumption shown):"$'\n'"$_zus_x"
}

# _zb_unclear_retired_v <var> <stage> <array_name> — the questions one stage's
# check retired (zb_unclear_dropped_lines_v), or empty.
_zb_unclear_retired_v() {
    local -n _zur="$1" _zur_a="$3"; local _zur_l _zur_x="" _zur_id _zur_y _zur_q
    _zur=""
    for _zur_l in ${_zur_a[@]+"${_zur_a[@]}"}; do
        local -a _zur_f=(); _zb_unclear_split_v _zur_f "$_zur_l"
        [[ -n "${_zur_f[0]}" && ( "${_zur_f[1]:-}" == answered || "${_zur_f[1]:-}" == "not needed" ) ]] || continue
        _zb_unclear_esc_v _zur_id "${_zur_f[0]}"; _zb_unclear_esc_v _zur_y "${_zur_f[2]:-}"; _zb_unclear_esc_v _zur_q "${_zur_f[3]:-}"
        _zur_x+=$'\n'"- ${_zur_id}: ${_zur_f[1]} — ${_zur_y}${_zur_q:+ — \"$_zur_q\"}"
    done
    [[ -n "$_zur_x" ]] || return 0
    _zur="**Questions $2 retired** (its check found the issue answers them, or no longer needs them):"$'\n'"$_zur_x"
}

# zb_unclear_markdown_v <var> <design_md> [result_json...] — the questions
# section of every report: design's, from its design file, then each result's
# (data.unclear), what its check retired (data.unclear_dropped) and the
# suspicions a lens left open (data.suspected, #2584), under the stage's name. Empty when there is none.
zb_unclear_markdown_v() {
    local -n _zum_out="$1"; local -a _zum=(); local _zum_s _zum_f _zum_st
    _zum_out=""
    zb_unclear_lines_v _zum "${2:-}"
    _zb_unclear_section_v _zum_s design _zum
    [[ -n "$_zum_s" ]] && _zum_out="$_zum_s"
    for _zum_f in "${@:3}"; do
        zb_unclear_result_lines_v _zum "$_zum_f"
        _zum_st="${_zum_f##*/}"; _zum_st="${_zum_st%.json}"; _zum_st="${_zum_st%-result}"; _zum_st="${_zum_st%-verdict}"
        _zb_unclear_section_v _zum_s "$_zum_st" _zum
        [[ -n "$_zum_s" ]] && _zum_out+="${_zum_out:+$'\n\n'}$_zum_s"
        zb_unclear_dropped_lines_v _zum "$_zum_f"
        _zb_unclear_retired_v _zum_s "$_zum_st" _zum
        [[ -n "$_zum_s" ]] && _zum_out+="${_zum_out:+$'\n\n'}$_zum_s"
        zb_unclear_suspected_lines_v _zum "$_zum_f"
        _zb_unclear_suspected_v _zum_s "$_zum_st" _zum
        [[ -n "$_zum_s" ]] && _zum_out+="${_zum_out:+$'\n\n'}$_zum_s"
    done
    return 0
}

# zb_unclear_suspected_lines_v <array_var> <result_json> — each suspicion a
# lens left open in the result's data.suspected (#2584, ADR-038), "<file> TAB
# <suspicion> TAB <confirm_by> TAB <quote>", with no fork and bounded as
# zb_unclear_dropped_lines_v is.
zb_unclear_suspected_lines_v() {
    local -n _zsl="$1"; local _zsl_t="" _zsl_n=0 _zsl_v _zsl_re='"suspected"[[:space:]]*:[[:space:]]*\['
    local _zsl_kv='^[[:space:],]*"([A-Za-z_]+)"[[:space:]]*:[[:space:]]*("'"$ZB_JSON_STR_RE"'"|null|true|false|-?[0-9][0-9.eE+-]*)'
    local -A _zsl_o=()
    _zsl=()
    _zb_unclear_read_v _zsl_t "${2:-}" || return 0
    [[ "$_zsl_t" =~ $_zsl_re ]] || return 0
    _zsl_t="${_zsl_t#*"${BASH_REMATCH[0]}"}"
    _zsl_t="${_zsl_t:0:$(( _ZB_UNCLEAR_READ_MAX * (_ZB_UNCLEAR_LINE_MAX * 6 + 200) ))}"
    while (( _zsl_n < _ZB_UNCLEAR_READ_MAX )) && [[ "$_zsl_t" =~ ^[[:space:],]*\{ ]]; do
        _zsl_t="${_zsl_t:${#BASH_REMATCH[0]}}"; _zsl_o=(); _zsl_n=$(( _zsl_n + 1 ))
        while [[ "$_zsl_t" =~ $_zsl_kv ]]; do
            _zsl_t="${_zsl_t:${#BASH_REMATCH[0]}}"
            [[ "${BASH_REMATCH[2]}" == \"* ]] || continue
            _zb_unclear_unesc_v _zsl_v "${BASH_REMATCH[3]}"; _zsl_o["${BASH_REMATCH[1]}"]="${_zsl_v//$'\t'/ }"
        done
        [[ "$_zsl_t" =~ ^[[:space:]]*\} ]] || break
        _zsl_t="${_zsl_t:${#BASH_REMATCH[0]}}"
        [[ -n "${_zsl_o[suspicion]:-}" ]] || continue
        _zsl+=("${_zsl_o[file]:-}"$'\t'"${_zsl_o[suspicion]}"$'\t'"${_zsl_o[confirm_by]:-}"$'\t'"${_zsl_o[quote]:-}")
    done
    return 0
}

# _zb_unclear_suspected_v <var> <stage> <array_name> — the suspicions one
# stage left open, for a person to check, or empty.
_zb_unclear_suspected_v() {
    local -n _zsv="$1" _zsv_a="$3"; local _zsv_l _zsv_x="" _zsv_f _zsv_s _zsv_c
    _zsv=""
    for _zsv_l in ${_zsv_a[@]+"${_zsv_a[@]}"}; do
        local -a _zsv_p=(); _zb_unclear_split_v _zsv_p "$_zsv_l"
        _zb_unclear_esc_v _zsv_f "${_zsv_p[0]:-}"; _zb_unclear_esc_v _zsv_s "${_zsv_p[1]:-}"; _zb_unclear_esc_v _zsv_c "${_zsv_p[2]:-}"
        _zsv_x+=$'\n'"- ${_zsv_f:+$_zsv_f: }${_zsv_s} — what would confirm it: ${_zsv_c:-not said}"
    done
    [[ -n "$_zsv_x" ]] || return 0
    _zsv="**Suspicions $2 could not confirm** (open: a person should check each):"$'\n'"$_zsv_x"
}

# zb_unclear_markdown <design_md> [result_json...] — the same, printed.
zb_unclear_markdown() {
    local _zm; zb_unclear_markdown_v _zm "$@"
    [[ -n "$_zm" ]] && printf '%s\n' "$_zm"
    return 0
}
