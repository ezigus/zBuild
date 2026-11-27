#!/usr/bin/env bash
# plugins/agent/issue-acceptance/lib/parse.sh — reading issue-acceptance's
# answer (ADR-072 §3). Split from plugin.sh (#2569: under 500 lines); its
# callers are there.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_IA_PARSE_LOADED:-}" ]] && return 0
_ZBUILD_IA_PARSE_LOADED=1
# #2571 (ADR-072 §3, ADR-069 §12): what the judge finds unclear in the issue.
# shellcheck source=../../../../scripts/lib/unclear.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/unclear.sh"

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
# #2571 (ADR-072 §3): each UNCLEAR line in the one form into _IA_UNCLEAR, and
# the answers to the questions it carried (_IA_UQ_CARRIED) into _IA_UQ_DROP
# (and the open ones' ids into _IA_UQ_KEPT). A question is never a verdict, so
# what is wrong with one — a new line not in the form (kept in _IA_UQ_BAD), a
# carried one with no usable answer — is _IA_UQ_PROBLEM, asked again once and
# then costing only itself, never _IA_PROBLEM. An UNSURE: line, the form
# before #2571, is still read.
# #2574 (ADR-072 §4): [want], the items asked (space separated: requirement
# and limit ids, `issue`, `unasked`): only their lines are read and required —
# a line about an item not asked is set aside; with no [want], every item is.
declare -gA _IA_BAD_AT=()
_IA_BAD_N=0; _IA_SEEN_N=0
_ia_parse() {
    local raw="$1" reqs="$2" issue="$3" repo="$4" lims="${5:-}" wm=0 want=" ${6:-} "
    [[ $# -ge 6 ]] && wm=1
    _IA_UNMET=(); _IA_UNSURE=(); _IA_UNASKED=(); _IA_PROBLEM=""; _IA_QUOTED=(); _IA_BAD_AT=()
    _IA_UNCLEAR=(); _IA_UQ_DROP=(); _IA_UQ_KEPT=(); _IA_UQ_BAD=(); _IA_UQ_PROBLEM=""
    local _uq_ans=""; local -a _uq_bad=()
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
    local l0
    while IFS= read -r l; do
        l0="$l"; judge_reply_line_v l "$l"
        # #2550 (ADR-072 §3): one line per limit; a broken one is unmet code.
        if [[ "$l" =~ ^(KEPT|BROKEN):[[:space:]]*(.*)$ ]]; then
            kind="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
            name="${rest%%|*}"; name="${name%"${name##*[![:space:]]}"}"; name="${name%:}"
            # An empty id is no key: refused before the lookup (lens review on #2550).
            [[ -n "$name" ]] || { bad+=("a $kind: line names no limit"); continue; }
            if [[ -z "${ltext[$name]+x}" ]]; then bad+=("$kind names $name, which is not a limit listed"); continue; fi
            (( wm )) && [[ "$want" != *" $name "* ]] && continue
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
            (( wm )) && [[ "$want" != *" unasked "* ]] && continue
            _ia_parse_unasked "${BASH_REMATCH[1]}" "$repo"; continue
        fi
        if [[ "$l" =~ ^UNCLEAR([[:space:]]|:) ]]; then
            # Read as written, its formatting aside: the reply-line reader
            # turns a bar into a colon.
            _ia_unclear_plain_v l0 "$l0"
            # An answer to a carried question, or a question it raises.
            if [[ "$l0" =~ ^UNCLEAR[[:space:]]+[^[:space:]:|]+[[:space:]]*: ]]; then _uq_ans+="$l0"$'\n'
            elif zb_unclear_check_v w "$l0" "$issue"; then _IA_UNCLEAR+=("$l0")
            else _uq_bad+=("the line \"${l0:0:120}\" $w"); _IA_UQ_BAD+=("$l0"); fi
            continue
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
        if (( wm )); then
            if [[ ${#order[@]} -gt 0 ]]; then [[ "$want" == *" $name "* ]] || continue
            else [[ "$want" == *" issue "* ]] || continue; fi
        fi
        seen["$name"]=1
        [[ "$kind" == MET ]] && continue
        _ia_fields "$rest"
        if [[ -z "$quote" ]]; then bad+=("$name has no QUOTE"); _IA_BAD_AT["$name"]="${bad[-1]}"; continue; fi
        [[ -n "$acc" ]] || acc="${rtext[$name]:-$name}"
        own="${rtext[$name]:-}"$'\n'"$issue"
        judge_quote_check_v w "$quote" "$own" "$repo" || { bad+=("$name's quote $w"); _IA_BAD_AT["$name"]="${bad[-1]}"; continue; }
        judge_quote_path_v qp "$quote" "$repo"; [[ -n "$qp" ]] && _IA_QUOTED+=("$qp")
        if [[ "$kind" == UNMET ]]; then _IA_UNMET+=("${fix:+$fix }$name: ${why:-it is not met} — $quote — ACCEPTED IF: $acc")
        else _IA_UNSURE+=("${fix:+$fix }$name: ${why:-it cannot be told} — $quote — ACCEPTED IF: $acc"); fi
    done <<< "$raw"
    local -a missing=(); local _ia_mreq=0
    for name in ${order[@]+"${order[@]}"}; do
        (( wm )) && [[ "$want" != *" $name "* ]] && continue
        [[ -n "${seen[$name]+x}" ]] || { missing+=("$name"); _IA_BAD_AT["$name"]="it has no line"; _ia_mreq=$(( _ia_mreq + 1 )); }
    done
    for name in "${!ltext[@]}"; do
        (( wm )) && [[ "$want" != *" $name "* ]] && continue
        [[ -n "${lseen[$name]+x}" ]] || missing+=("$name")
    done
    [[ ${#missing[@]} -gt 0 ]] && bad=("it has no line for ${missing[*]}" ${bad[@]+"${bad[@]}"})
    # #2598: every problem is some requirement's own when the only ones besides
    # the per-requirement ones are its missing lines (a limit's is not).
    _IA_BAD_N=${#bad[@]}; _IA_SEEN_N=${#seen[@]}
    if (( ${#missing[@]} > 0 )); then
        if (( _ia_mreq == ${#missing[@]} )); then _IA_BAD_N=$(( _IA_BAD_N - 1 + _ia_mreq )); else _IA_BAD_N=-1; fi
    fi
    if [[ -n "${_IA_UQ_CARRIED:-}" ]]; then
        local _uq_p=""
        zb_unclear_answers_v _IA_UQ_KEPT _IA_UQ_DROP _uq_p "$_uq_ans" "$_IA_UQ_CARRIED" "$issue"
        [[ -n "$_uq_p" ]] && _uq_bad+=("$_uq_p")
    fi
    for w in ${_uq_bad[@]+"${_uq_bad[@]}"}; do _IA_UQ_PROBLEM+="${_IA_UQ_PROBLEM:+; }$w"; done
    # With no list, an answer must still judge something: no line is no answer.
    [[ ${#order[@]} -eq 0 && ${#seen[@]} -eq 0 && ${#bad[@]} -eq 0 && ( $wm -eq 0 || "$want" == *" issue "* ) ]] \
        && bad=("it has no MET:, UNMET: or UNSURE: line")
    if [[ ${#bad[@]} -gt 0 ]]; then
        judge_problems_join_v _IA_PROBLEM bad
    fi
    return 0
}

# _ia_unclear_plain_v <var> <line> — an UNCLEAR line as the model wrote it,
# with the formatting around it aside — spaces, a quote or heading mark, a list
# bullet or number, bold or code marks — and its bars kept.
_ia_unclear_plain_v() { zb_unclear_plain_v "$@"; }

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
    # #2629 (ADR-075 §3): a part nothing asks for is accepted only without it,
    # or with a requirement that asks for it — never on a condition about how
    # it is done. The check writes it (ADR-072); one that says otherwise is not
    # an answer, and is asked again, saying why.
    local _acc_l="${acc,,}" _acc_re='(without|take[s]?( it| them| this| that)? out|taken out|remov|revert|undo|restor|back out|no longer|requirement)'
    [[ "$_acc_l" =~ $_acc_re ]] || { bad+=("UNASKED $part: its ACCEPTED IF must be the change without it, or a requirement that asks for it — not a condition about how it is done (it said: $acc)"); return 0; }
    _IA_UNASKED+=("$mark$part: ${why:-no requirement asks for it} — $quote — ACCEPTED IF: $acc")
}

# _ia_unclear_carried_load <result_json> — the questions issue-acceptance's last
# result carries (data.unclear), readable ones only: _IA_UQ_CARRIED (a line
# each, for its next call to judge) and _IA_UQ_JSON (what a result keeps until
# they are judged). #2571 (ADR-072 §3).
_ia_unclear_carried_load() {
    local -a _iuc=() _iuc_ok=(); local _iuc_l _iuc_p
    _IA_UQ_CARRIED=""; _IA_UQ_JSON="[]"; _IA_UQ_NEW=(); _IA_UQ_DROPPED="[]"; _IA_UQ_NOTES=""
    _IA_UQ_DROP=(); _IA_UQ_KEPT=(); _IA_UQ_BAD=(); _IA_UQ_PROBLEM=""
    zb_unclear_result_lines_v _iuc "${1:-}"
    for _iuc_l in ${_iuc[@]+"${_iuc[@]}"}; do
        zb_unclear_parse_v _iuc_p "$_iuc_l" || continue
        _IA_UQ_CARRIED+="$_iuc_l"$'\n'; _iuc_ok+=("$_iuc_l")
    done
    zb_unclear_result_json_v _IA_UQ_JSON _iuc_ok
}

# _ia_unclear_settle — after a usable answer: _IA_UQ_JSON, each carried question
# not dropped, then each one raised now whose id was not carried; _IA_UQ_NEW,
# the questions raised now, each a finding. Only its own call retires its
# question: a dropped one is gone — recorded, with its WHY, QUOTE and the
# question, in _IA_UQ_DROPPED (JSON, for data.unclear_dropped:
# zb_unclear_dropped_json_v) — and an open one is kept. _IA_UQ_NOTES: a line
# for each carried one with no usable answer, each new line left out, and any
# over the most a stage carries.
_ia_unclear_settle() {
    local -A _ius_drop=() _ius_have=() _ius_open=(); local -a _ius_out=(); local _ius_l _ius_p _ius_id _ius_n=""
    _IA_UQ_NEW=(); _IA_UQ_NOTES=""
    zb_unclear_dropped_json_v _IA_UQ_DROPPED _IA_UQ_DROP "${_IA_UQ_CARRIED:-}"
    for _ius_l in ${_IA_UQ_DROP[@]+"${_IA_UQ_DROP[@]}"}; do _ius_drop["${_ius_l%%$'\t'*}"]=1; done
    for _ius_l in ${_IA_UQ_KEPT[@]+"${_IA_UQ_KEPT[@]}"}; do _ius_open["$_ius_l"]=1; done
    while IFS= read -r _ius_l; do
        [[ -n "$_ius_l" ]] && zb_unclear_parse_v _ius_p "$_ius_l" || continue
        _ius_id="${_ius_p%%$'\t'*}"
        [[ -n "${_ius_have[$_ius_id]+x}" ]] && continue
        _ius_have["$_ius_id"]=1
        [[ -n "${_ius_drop[$_ius_id]+x}" ]] && continue
        [[ -n "${_ius_open[$_ius_id]+x}" ]] || _IA_UQ_NOTES+="UNCLEAR $_ius_id: no usable answer after it was asked again — kept open"$'\n'
        _ius_out+=("$_ius_l")
    done <<< "${_IA_UQ_CARRIED:-}"
    for _ius_l in ${_IA_UQ_BAD[@]+"${_IA_UQ_BAD[@]}"}; do
        _IA_UQ_NOTES+="an UNCLEAR line was left out, still not in its form after it was asked again: ${_ius_l:0:200}"$'\n'
    done
    for _ius_l in ${_IA_UNCLEAR[@]+"${_IA_UNCLEAR[@]}"}; do
        zb_unclear_parse_v _ius_p "$_ius_l" || continue
        _ius_id="${_ius_p%%$'\t'*}"
        [[ -n "${_ius_have[$_ius_id]+x}" ]] && continue
        _ius_have["$_ius_id"]=1; _ius_out+=("$_ius_l"); _IA_UQ_NEW+=("$_ius_l")
    done
    zb_unclear_result_json_v _IA_UQ_JSON _ius_out _ius_n
    [[ -n "$_ius_n" ]] && _IA_UQ_NOTES+="$_ius_n"$'\n'
    return 0
}

# _ia_unchecked_to_unmet — after the re-ask (#2598, ADR-072 §3): when every
# problem left is some requirement's own (a limit's BROKEN line is not:
# it still makes the answer unusable), each such one is unmet,
# saying it could not be checked and why, and the answer is used — the judged
# ones are kept and the stage fails on the unchecked. A problem no item owns
# leaves the answer unusable.
# Called again after the answer is read with its kept items (items.sh), which
# has no line for one set aside: why it was set aside is kept from the first
# call (_IA_UNCHECKED_WHY).
declare -gA _IA_UNCHECKED_WHY=()
_ia_unchecked_to_unmet() {
    # An answer that judged no requirement at all is no answer (review on #2598).
    [[ -n "$_IA_PROBLEM" && ${#_IA_BAD_AT[@]} -gt 0 && "$_IA_BAD_N" -eq ${#_IA_BAD_AT[@]} && "${_IA_SEEN_N:-0}" -gt 0 ]] || return 0
    local n w
    for n in "${!_IA_BAD_AT[@]}"; do
        w="${_IA_UNCHECKED_WHY[$n]:-${_IA_BAD_AT[$n]}}"; _IA_UNCHECKED_WHY["$n"]="$w"
        _IA_UNMET+=("$n: this requirement could not be checked ($w) — ACCEPTED IF: its answer can be checked against the change")
    done
    _IA_PROBLEM=""
}
