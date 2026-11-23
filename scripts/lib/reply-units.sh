#!/usr/bin/env bash
# scripts/lib/reply-units.sh — a model's reply read in whole units, however many
# lines each spans (#2460).
#
# A model wraps long lines: a REQUIREMENT, an UNMET, a REASON or an ANSWER can
# carry on to the next line, and a list can sit under its key as bullets. A
# reader that took one line per item kept half an item, or none. Every reader
# of a reply joins it first, then reads it line by line as before.
#
# Sourced library: no set -euo pipefail.
[[ -n "${_ZBUILD_REPLY_UNITS_LOADED:-}" ]] && return 0
_ZBUILD_REPLY_UNITS_LOADED=1

# A line that starts a unit of its own: a `KEY:` marker (capitals, digits, _ or
# -, then a colon — `SPEC-3:` too), an ANSWER, LOOP_COMPLETE, a list item, a
# heading or a code fence. Markdown emphasis or a quote mark may come first.
# #2467: a check's line about one part of a SPEC — `FRSH-1 Then:`,
# `FRSH-1 And:`, `FRSH-1 sections:`, `FRSH-1 cleanup:` (#2543), an old `FRSH-1 Then 2:` — starts a unit too, as do `FRSH-1 Title:` and `Steps:` (#2555),
# and build's answer to a design step, `step 2:` (#2565) or a part, `step 1.2:` (#2586), and design's check's
# `Decision:` answer of a check — `Decision: ok` and its other words, not prose
# that happens to start with the word (#2567). A question in the one form, and
# a check's answer to one — `UNCLEAR <id> | …`, `UNCLEAR <id>: open` — starts a
# unit too (#2571).
_ZB_RU_START='^[[:space:]>*_`]*([A-Z][A-Z0-9_-]*:|UNCLEAR[[:space:]]|[A-Z][A-Z0-9_]*-[0-9]+[[:space:]]+(Title|Given|When|Then|And|Cleanup|sections|cleanup)([[:space:]]+[0-9]+)?:|Steps:|Decisions?:[[:space:]]*(ok|not-asked|contradicts|new-owner|unhandled)|[Ss][Tt][Ee][Pp][[:space:]]+[0-9]+([.][0-9]+)?[[:space:]]*:|[Aa][Nn][Ss][Ww][Ee][Rr][[:space:]]|LOOP_COMPLETE|#|```|[-*+][[:space:]]|[0-9]+[.)][[:space:]])'
_ZB_RU_ITEM='^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+(.*)$'
_ZB_RU_KEY_ONLY='^[[:space:]>*_`]*([A-Z][A-Z0-9_-]*):[[:space:]*_`]*$'

# zb_reply_plain_v <var> <text> — <text> with its formatting and spacing aside
# (#2474, ADR-072 §3): no `*` or backticks, no underscore that is not inside a
# word (done_wrong keeps its own), and tabs and runs of spaces as one space.
zb_reply_plain_v() {
    local -n _rp="$1"
    local _rp_t="${2//[*\`]/}" _rp_o="" _rp_p=" " _rp_c _rp_i
    if [[ "$_rp_t" == *_* ]]; then
        for (( _rp_i = 0; _rp_i < ${#_rp_t}; _rp_i++ )); do
            _rp_c="${_rp_t:_rp_i:1}"
            [[ "$_rp_c" == _ && ! ( "$_rp_p" == [[:alnum:]] && "${_rp_t:_rp_i+1:1}" == [[:alnum:]_] ) ]] && continue
            _rp_o+="$_rp_c"; _rp_p="$_rp_c"
        done
        _rp_t="$_rp_o"
    fi
    _rp_t="${_rp_t//$'\t'/ }"; while [[ "$_rp_t" == *"  "* ]]; do _rp_t="${_rp_t//  / }"; done
    _rp="$_rp_t"
}

# judge_reply_line_v <var> <line> — one line of a judge's reply as every reader
# reads it (#2474, ADR-072 §3). Its structure — the id, the part and the word —
# is read with formatting and spacing aside: bold, italics, code marks, a list
# bullet or number, a quote or heading mark, a table's borders and cells. WHY:,
# ACCEPTED IF: and QUOTE: are the separators, written back in that order as
# " | WHY: ", " | ACCEPTED IF: " and " | QUOTE: " whatever order they came in;
# what follows each is kept as written, without the marks around it. #2569
# (ADR-072 §3): ACCEPTED IF is every check's word for what would be accepted;
# an old INSTEAD: is read as it. A label in capitals is read anywhere; one in
# any other case ("Accepted if:") only after a `|`, so a word in a WHY is never
# taken for one. After the QUOTE, only a label after a `|` ends it: a QUOTE is
# copied text, and what follows its own label is the quote (review on #2569).
_ZB_JR_ANY='(^|[^A-Za-z0-9])(WHY|ACCEPTED IF|INSTEAD|QUOTE)[*_`]*:'
_ZB_JR_BAR='[|][[:space:]*_`]*(WHY|ACCEPTED IF|INSTEAD|QUOTE)[*_`]*:'
_ZB_JR_BARQ='[|][[:space:]*_`]*(WHY|ACCEPTED IF|INSTEAD)[*_`]*:'
judge_reply_line_v() {
    local -n _jrl="$1"
    local _jr_l="$2" _jr_u="${2^^}" _jr_off=0 _jr_r _jr_ru _jr_m _jr_pre _jr_p1 _jr_p2 _jr_n1 _jr_n2 _jr_s1 _jr_s2
    local _jr_head="" _jr_qseen=0 _jr_name="" _jr_vs=0 _jr_cut
    local -A _jr_f=()
    # Each label, leftmost first: the text before the first is the head, and
    # each label's text runs to the next label.
    while :; do
        _jr_r="${_jr_l:_jr_off}"; _jr_ru="${_jr_u:_jr_off}"; _jr_p1=-1; _jr_p2=-1
        if (( ! _jr_qseen )) && [[ "$_jr_r" =~ $_ZB_JR_ANY ]]; then
            _jr_m="${BASH_REMATCH[0]}"; _jr_pre="${_jr_r%%"$_jr_m"*}"
            _jr_p1=$(( ${#_jr_pre} + ${#BASH_REMATCH[1]} )); _jr_s1=$(( ${#_jr_pre} + ${#_jr_m} )); _jr_n1="${BASH_REMATCH[2]}"
        fi
        if (( _jr_qseen )); then [[ "$_jr_ru" =~ $_ZB_JR_BARQ ]] || _jr_ru=""
        else [[ "$_jr_ru" =~ $_ZB_JR_BAR ]] || _jr_ru=""; fi
        if [[ -n "$_jr_ru" ]]; then
            _jr_m="${BASH_REMATCH[0]}"; _jr_pre="${_jr_ru%%"$_jr_m"*}"
            _jr_p2=${#_jr_pre}; _jr_s2=$(( ${#_jr_pre} + ${#_jr_m} )); _jr_n2="${BASH_REMATCH[1]}"
        fi
        if (( _jr_p2 >= 0 && ( _jr_p1 < 0 || _jr_p2 < _jr_p1 ) )); then _jr_p1=$_jr_p2; _jr_s1=$_jr_s2; _jr_n1="$_jr_n2"
        elif (( _jr_p1 < 0 )); then break; fi
        _jr_cut="${_jr_l:_jr_vs:_jr_off + _jr_p1 - _jr_vs}"
        if [[ -z "$_jr_name" ]]; then _jr_head="$_jr_cut"
        elif [[ -z "${_jr_f[$_jr_name]+x}" ]]; then _jr_f["$_jr_name"]="$_jr_cut"; fi
        _jr_name="$_jr_n1"; [[ "$_jr_name" == QUOTE ]] && _jr_qseen=1
        _jr_vs=$(( _jr_off + _jr_s1 )); _jr_off=$_jr_vs
    done
    if [[ -z "$_jr_name" ]]; then _jr_head="$_jr_l"
    elif [[ -z "${_jr_f[$_jr_name]+x}" ]]; then _jr_f["$_jr_name"]="${_jr_l:_jr_vs}"; fi
    # An old INSTEAD is ACCEPTED IF, when there is no ACCEPTED IF.
    [[ -z "${_jr_f[ACCEPTED IF]+x}" && -n "${_jr_f[INSTEAD]+x}" ]] && _jr_f["ACCEPTED IF"]="${_jr_f[INSTEAD]}"
    zb_reply_plain_v _jr_head "$_jr_head"
    _jr_head="${_jr_head#"${_jr_head%%[![:space:]>#|+-]*}"}"
    [[ "$_jr_head" =~ ^[0-9]+[.\)][[:space:]]+(.*)$ ]] && _jr_head="${BASH_REMATCH[1]}"
    _judge_reply_trim_v _jr_head "$_jr_head"
    # A table row's cells: the first border after the id is its colon.
    [[ "$_jr_head" != *:* && "$_jr_head" == *" | "* ]] && _jr_head="${_jr_head/ | /: }"
    _jr_head="${_jr_head//|/ }"; while [[ "$_jr_head" == *"  "* ]]; do _jr_head="${_jr_head//  / }"; done
    _jrl="$_jr_head"
    local _jr_k _jr_v
    for _jr_k in WHY "ACCEPTED IF" QUOTE; do
        [[ -n "${_jr_f[$_jr_k]+x}" ]] || continue
        _judge_reply_trim_v _jr_v "${_jr_f[$_jr_k]}"; _jrl+=" | $_jr_k: $_jr_v"
    done
    return 0
}

# judge_reply_field_v <var> <rest> <FIELD> — the text of one separator a line
# read by judge_reply_line_v carries (WHY, ACCEPTED IF or QUOTE), up to the next
# one; empty when it has none (#2569: the one reader every check uses).
judge_reply_field_v() {
    local -n _jrf="$1"; local _jrf_r="$2"
    _jrf=""
    [[ "$_jrf_r" == *"| $3:"* ]] || return 0
    _jrf_r="${_jrf_r#*"| $3:"}"
    case "$3" in
        WHY) _jrf_r="${_jrf_r%%| ACCEPTED IF:*}"; _jrf_r="${_jrf_r%%| QUOTE:*}" ;;
        "ACCEPTED IF") _jrf_r="${_jrf_r%%| QUOTE:*}" ;;
    esac
    _jrf_r="${_jrf_r#"${_jrf_r%%[![:space:]]*}"}"; _jrf="${_jrf_r%"${_jrf_r##*[![:space:]]}"}"
}

# _judge_reply_trim_v <var> <text> — <text> without the spaces, table borders and
# bold marks around it.
_judge_reply_trim_v() {
    local -n _jrt="$1"
    _jrt="${2#"${2%%[![:space:]|*]*}"}"; _jrt="${_jrt%"${_jrt##*[![:space:]|*]}"}"
}

# zb_reply_join_v <var> <reply> — <reply> with each continued line joined, by
# one space, to the line it continues. A line continues the one before it unless
# it is blank, follows a blank, or starts a unit of its own. A list straight
# under a `KEY:` with no text becomes one `KEY: <item>` line per item. Blank
# lines are kept. Read by the shell: it runs on every reply (ADR-065 §5).
zb_reply_join_v() {
    local -n _rj="$1"
    local _zbrj_l _zbrj_t _zbrj_cur="" _zbrj_key="" _zbrj_have=0 _zbrj_blank=1
    _rj=""
    local _zbrj_p
    while IFS= read -r _zbrj_l || [[ -n "$_zbrj_l" ]]; do
        _zbrj_t="${_zbrj_l#"${_zbrj_l%%[![:space:]]*}"}"; _zbrj_t="${_zbrj_t%"${_zbrj_t##*[![:space:]]}"}"
        # #2567 (ADR-060): a fence line is a line of its own — nothing joins
        # it, and it joins nothing — so a reader that tracks blocks (design.md's)
        # still sees them; the lines inside a block join as anywhere else.
        if [[ "$_zbrj_t" == '```'* ]]; then
            (( _zbrj_have )) && _rj+="$_zbrj_cur"$'\n'
            _rj+="$_zbrj_l"$'\n'; _zbrj_cur=""; _zbrj_have=0; _zbrj_key=""; _zbrj_blank=1
            continue
        fi
        # Where a unit starts is read with the formatting aside (#2474): its
        # start, not the whole line, so a long reply costs little.
        zb_reply_plain_v _zbrj_p "${_zbrj_l:0:80}"
        if [[ -z "$_zbrj_t" ]]; then
            (( _zbrj_have )) && _rj+="$_zbrj_cur"$'\n'
            _rj+=$'\n'; _zbrj_cur=""; _zbrj_have=0; _zbrj_key=""; _zbrj_blank=1
            continue
        fi
        if [[ -n "$_zbrj_key" && "$_zbrj_l" =~ $_ZB_RU_ITEM ]]; then
            local _zbrj_item="${BASH_REMATCH[2]}"
            # The bare `KEY:` line itself is not an item.
            (( _zbrj_have )) && ! [[ "$_zbrj_cur" =~ $_ZB_RU_KEY_ONLY ]] && _rj+="$_zbrj_cur"$'\n'
            _zbrj_cur="$_zbrj_key: $_zbrj_item"; _zbrj_have=1; _zbrj_blank=0
            continue
        fi
        if (( _zbrj_blank || ! _zbrj_have )) || [[ "$_zbrj_p" =~ $_ZB_RU_START ]]; then
            (( _zbrj_have )) && _rj+="$_zbrj_cur"$'\n'
            _zbrj_cur="$_zbrj_l"; _zbrj_have=1; _zbrj_key=""
            [[ "$_zbrj_l" =~ $_ZB_RU_KEY_ONLY ]] && _zbrj_key="${BASH_REMATCH[1]}"
        else
            # A plain line under an empty `KEY:` is that key's text.
            if [[ -n "$_zbrj_key" && "$_zbrj_cur" =~ $_ZB_RU_KEY_ONLY ]]; then _zbrj_cur="$_zbrj_key: $_zbrj_t"
            else _zbrj_cur+=" $_zbrj_t"; fi
        fi
        _zbrj_blank=0
    done <<< "${2:-}"
    (( _zbrj_have )) && _rj+="$_zbrj_cur"$'\n'
    _rj="${_rj%$'\n'}"
}
