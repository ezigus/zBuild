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
# `FRSH-1 And:`, `FRSH-1 sections:`, an old `FRSH-1 Then 2:` — starts a unit too.
_ZB_RU_START='^[[:space:]>*_`]*([A-Z][A-Z0-9_-]*:|[A-Z][A-Z0-9_]*-[0-9]+[[:space:]]+(Given|When|Then|And|Cleanup|sections)([[:space:]]+[0-9]+)?:|[Aa][Nn][Ss][Ww][Ee][Rr][[:space:]]|LOOP_COMPLETE|#|```|[-*+][[:space:]]|[0-9]+[.)][[:space:]])'
_ZB_RU_ITEM='^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+(.*)$'
_ZB_RU_KEY_ONLY='^[[:space:]>*_`]*([A-Z][A-Z0-9_-]*):[[:space:]*_`]*$'

# zb_reply_join_v <var> <reply> — <reply> with each continued line joined, by
# one space, to the line it continues. A line continues the one before it unless
# it is blank, follows a blank, or starts a unit of its own. A list straight
# under a `KEY:` with no text becomes one `KEY: <item>` line per item. Blank
# lines are kept. Read by the shell: it runs on every reply (ADR-065 §5).
zb_reply_join_v() {
    local -n _rj="$1"
    local _zbrj_l _zbrj_t _zbrj_cur="" _zbrj_key="" _zbrj_have=0 _zbrj_blank=1
    _rj=""
    while IFS= read -r _zbrj_l || [[ -n "$_zbrj_l" ]]; do
        _zbrj_t="${_zbrj_l#"${_zbrj_l%%[![:space:]]*}"}"; _zbrj_t="${_zbrj_t%"${_zbrj_t##*[![:space:]]}"}"
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
        if (( _zbrj_blank || ! _zbrj_have )) || [[ "$_zbrj_l" =~ $_ZB_RU_START ]]; then
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
