#!/usr/bin/env bash
# plugins/agent/issue-acceptance/lib/parse.sh — reading issue-acceptance's
# answer (ADR-072 §3). Split from plugin.sh (#2569: under 500 lines); its
# callers are there.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_IA_PARSE_LOADED:-}" ]] && return 0
_ZBUILD_IA_PARSE_LOADED=1

# What an UNASKED with no ACCEPTED IF is told (#2569, ADR-072 §3). An UNMET,
# UNSURE or BROKEN with none is judged against its requirement or limit, whose
# own words are its ACCEPTED IF (review on #2569); an UNASKED part has no line
# of its own, so the check writes what would be accepted.
_IA_NO_ACC="has no ACCEPTED IF — say what would be accepted: the change without it, or the requirement that would ask for it"

# _ia_fields <rest> — a line's WHY, ACCEPTED IF and QUOTE, into the caller's
# why, acc and quote (judge_reply_field_v).
_ia_fields() {
    judge_reply_field_v why "$1" WHY; judge_reply_field_v acc "$1" "ACCEPTED IF"; judge_reply_field_v quote "$1" QUOTE
    return 0
}

# _ia_parse <reply> <requirements> <issue> <repo> — each MET:/UNMET:/UNSURE:
# line (ADR-072 §3) into _IA_UNMET ("[fix-code] <id>: <why> — <quote> —
# ACCEPTED IF: <the check's>", #2569; an
# unmarked line keeps no mark, #2452) and
# _IA_UNSURE (marked the same way when the line says what would fix it,
# #2569). _IA_PROBLEM says what makes the answer unusable: a requirement
# with no line, a line naming none of them, a complaint with no quote or a
# quote that is not there. A line that names nothing ("none") is no line.
# #2508 (ADR-072 §3): each UNASKED: line — a part of the change no requirement
# asks for, with the code that does it — into _IA_UNASKED ("<part>: <why> —
# <quote>"); its quote must be in a file, and `UNASKED: none` is no line.
_ia_parse() {
    local raw="$1" reqs="$2" issue="$3" repo="$4" lims="${5:-}"
    _IA_UNMET=(); _IA_UNSURE=(); _IA_UNASKED=(); _IA_PROBLEM=""; _IA_QUOTED=()
    local -A rtext=() seen=() ltext=() lseen=()
    local -a order=() bad=()
    local l kind rest fix name why quote acc w qp own
    while IFS= read -r l; do
        [[ "$l" =~ ^-[[:space:]]+([A-Za-z0-9]+-[0-9]+):[[:space:]]*(.*)$ ]] || continue
        rtext["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"; order+=("${BASH_REMATCH[1]}")
    done <<< "$reqs"
    while IFS= read -r l; do
        [[ "$l" =~ ^-[[:space:]]+([A-Za-z0-9]+-[0-9]+):[[:space:]]*(.*)$ ]] || continue
        ltext["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    done <<< "$lims"
    while IFS= read -r l; do
        judge_reply_line_v l "$l"
        # #2550 (ADR-072 §3): one line per limit; a broken one is unmet code.
        if [[ "$l" =~ ^(KEPT|BROKEN):[[:space:]]*(.*)$ ]]; then
            kind="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
            name="${rest%%|*}"; name="${name%"${name##*[![:space:]]}"}"; name="${name%:}"
            # An empty id is no key: refused before the lookup (lens review on #2550).
            [[ -n "$name" ]] || { bad+=("a $kind: line names no limit"); continue; }
            if [[ -z "${ltext[$name]+x}" ]]; then bad+=("$kind names $name, which is not a limit listed"); continue; fi
            lseen["$name"]=1
            [[ "$kind" == KEPT ]] && continue
            _ia_fields "$rest"
            if [[ -z "$quote" ]]; then bad+=("BROKEN $name has no QUOTE"); continue; fi
            [[ -n "$acc" ]] || acc="${ltext[$name]}"
            judge_quote_check_v w "$quote" "" "$repo" || { bad+=("BROKEN $name: its quote $w"); continue; }
            judge_quote_path_v qp "$quote" "$repo"; [[ -n "$qp" ]] && _IA_QUOTED+=("$qp")
            _IA_UNMET+=("[fix-code] $name: ${why:-the change does what this limit forbids} (${ltext[$name]}) — $quote — ACCEPTED IF: $acc")
            continue
        fi
        if [[ "$l" =~ ^UNASKED:[[:space:]]*(.*)$ ]]; then
            _ia_parse_unasked "${BASH_REMATCH[1]}" "$repo"; continue
        fi
        [[ "$l" =~ ^(MET|UNMET|UNSURE):[[:space:]]*(.*)$ ]] || continue
        kind="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; fix=""
        [[ "$kind" != MET && "$rest" =~ ^(\[fix-(code|design)\])[[:space:]]*(.*)$ ]] && { fix="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[3]}"; }
        name="${rest%%|*}"; name="${name%"${name##*[![:space:]]}"}"; name="${name%:}"
        shopt -q nocasematch; local _ncm=$?
        shopt -s nocasematch
        [[ -z "$name" || "$name" =~ ^\(?(none|omitted|n/a|nothing)\)?\.?$ ]] && { (( _ncm )) && shopt -u nocasematch; continue; }
        (( _ncm )) && shopt -u nocasematch
        if [[ ${#order[@]} -gt 0 && -z "${rtext[$name]+x}" ]]; then
            bad+=("$kind names $name, which is not a requirement listed"); continue
        fi
        seen["$name"]=1
        [[ "$kind" == MET ]] && continue
        _ia_fields "$rest"
        if [[ -z "$quote" ]]; then bad+=("$name has no QUOTE"); continue; fi
        [[ -n "$acc" ]] || acc="${rtext[$name]:-$name}"
        own="${rtext[$name]:-}"$'\n'"$issue"
        judge_quote_check_v w "$quote" "$own" "$repo" || { bad+=("$name's quote $w"); continue; }
        judge_quote_path_v qp "$quote" "$repo"; [[ -n "$qp" ]] && _IA_QUOTED+=("$qp")
        if [[ "$kind" == UNMET ]]; then _IA_UNMET+=("${fix:+$fix }$name: ${why:-it is not met} — $quote — ACCEPTED IF: $acc")
        else _IA_UNSURE+=("${fix:+$fix }$name: ${why:-it cannot be told} — $quote — ACCEPTED IF: $acc"); fi
    done <<< "$raw"
    local -a missing=()
    for name in ${order[@]+"${order[@]}"}; do [[ -n "${seen[$name]+x}" ]] || missing+=("$name"); done
    for name in "${!ltext[@]}"; do [[ -n "${lseen[$name]+x}" ]] || missing+=("$name"); done
    [[ ${#missing[@]} -gt 0 ]] && bad=("it has no line for ${missing[*]}" ${bad[@]+"${bad[@]}"})
    # With no list, an answer must still judge something: no line is no answer.
    [[ ${#order[@]} -eq 0 && ${#seen[@]} -eq 0 && ${#bad[@]} -eq 0 ]] \
        && bad=("it has no MET:, UNMET: or UNSURE: line")
    if [[ ${#bad[@]} -gt 0 ]]; then
        local IFS=';'; _IA_PROBLEM="${bad[*]}"; _IA_PROBLEM="${_IA_PROBLEM//;/; }"
    fi
    return 0
}

# _ia_parse_unasked <rest> <repo> — one UNASKED: line, in _ia_parse's scope
# (bad, _IA_UNASKED, _IA_QUOTED).
_ia_parse_unasked() {
    local rest="$1" repo="$2" part why="" quote="" acc="" w qp
    part="${rest%%|*}"; part="${part%"${part##*[![:space:]]}"}"
    shopt -q nocasematch; local _ncm=$?
    shopt -s nocasematch
    [[ -z "$part" || "$part" =~ ^\(?(none|nothing|n/a)\)?\.?$ ]] && { (( _ncm )) && shopt -u nocasematch; return 0; }
    (( _ncm )) && shopt -u nocasematch
    _ia_fields "$rest"
    if [[ -z "$quote" ]]; then bad+=("UNASKED $part has no QUOTE"); return 0; fi
    [[ -n "$acc" ]] || { bad+=("UNASKED $part $_IA_NO_ACC"); return 0; }
    # No own words: the quote is the code that does it, in a file.
    judge_quote_check_v w "$quote" "" "$repo" || { bad+=("UNASKED $part: its quote $w"); return 0; }
    judge_quote_path_v qp "$quote" "$repo"; [[ -n "$qp" ]] && _IA_QUOTED+=("$qp")
    # #2523: a part in a test file is the tests' to fix, not the code's.
    local mark=""; [[ -n "$qp" ]] && zb_is_test_path "$qp" "$repo" && mark="[fix-test] "
    _IA_UNASKED+=("$mark$part: ${why:-no requirement asks for it} — $quote — ACCEPTED IF: $acc")
}
