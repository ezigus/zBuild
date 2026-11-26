#!/usr/bin/env bash
# scripts/lib/stage-requires.sh — a stage runs only when the earlier stages it
# requires passed (#2611, ADR-068 §3). The template names them (`requires:`,
# template_stage_requires); the runner asks stage_requires_gate before each
# top-level unit. A stage whose requires were met is told so
# (ZBUILD_STAGE_REQUIRES_MET=yes): pr-open and merge refuse without it, so a PR
# never opens on a run that did not pass what its template asks (ADR-001).
#
# Sourced library: no set -euo pipefail.
[[ -n "${_ZBUILD_STAGE_REQUIRES_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_REQUIRES_LOADED=1

# stage_requires_gate <state_file> <stage> — rc 0 when every stage <stage>
# requires is complete with a pass (or no verdict), exporting
# ZBUILD_STAGE_REQUIRES_MET=yes when it requires any; rc 1 when one is not,
# with _STAGE_REQUIRES_UNMET naming each (space-separated). A stage that
# requires nothing is never told it was met.
_STAGE_REQUIRES_UNMET=""
# _stage_requires_unmet_v <var> <state_file> <names> — those of <names> not
# complete with a pass; fail closed: no state, or one jq cannot read, meets nothing.
_stage_requires_unmet_v() {
    local -n _sru="$1"; local _n _st _vd _ask="" _known=""
    # A unit this shell recorded is read from memory (_ZB_STATE_MEMO, the state
    # writers'); only the rest are read from the file.
    for _n in $3; do
        if [[ -n "${_ZB_STATE_MEMO["$2|$_n|s"]+x}" ]]; then
            _st="${_ZB_STATE_MEMO["$2|$_n|s"]}"; _vd="${_ZB_STATE_MEMO["$2|$_n|v"]:-pass}"
            [[ "$_st" == complete && ( "$_vd" == pass || "$_vd" == complete ) ]] || _known+="$_n "
        else _ask+="$_n "; fi
    done
    _sru="${_known% }"
    [[ -n "$_ask" ]] || return 0
    local _fromfile=""
    _stage_requires_unmet_file_v _fromfile "$2" "${_ask% }"
    [[ -n "$_fromfile" ]] && _sru="${_sru:+$_sru }$_fromfile"
    return 0
}
_stage_requires_unmet_file_v() {
    local -n _sru="$1"
    if [[ ! -s "$2" ]] || ! _sru="$(jq -r --arg n "$3" '
        . as $s | [($n | split(" ") | map(select(length > 0)))[]
        | select((($s.stage_statuses // {})[.] // "") != "complete"
                 or ((($s.stage_verdicts // {})[.] // "pass") | IN("pass", "complete") | not))]
        | join(" ")' "$2" 2>/dev/null)"; then
        _sru="$3"
    fi
}
stage_requires_gate() {
    local sf="$1" names v="_TPL_STAGE_REQUIRES_${2//-/_}"
    unset ZBUILD_STAGE_REQUIRES_MET
    _STAGE_REQUIRES_UNMET=""
    names="${!v:-}"   # template_stage_requires, without a process per unit
    [[ -n "${names// /}" ]] || return 0
    _stage_requires_unmet_v _STAGE_REQUIRES_UNMET "$sf" "$names"
    [[ -z "$_STAGE_REQUIRES_UNMET" ]] || return 1
    export ZBUILD_STAGE_REQUIRES_MET=yes
    return 0
}

# stage_requires_ahead <state_file> <next_index> — rc 1 when a unit from
# <next_index> on (in _TPL_DISPATCH_UNITS) requires a unit that has already run
# and did not pass: the run ends now, not after every unit between has run
# (#2611 review). _STAGE_REQUIRES_HELD names that unit, _STAGE_REQUIRES_UNMET
# what it requires. One jq per unit whose requires include a unit that ran.
_STAGE_REQUIRES_HELD=""
stage_requires_ahead() {
    local sf="$1" from="${2:-0}" j id v n done=" " ask
    _STAGE_REQUIRES_HELD=""; _STAGE_REQUIRES_UNMET=""
    for (( j = 0; j < from && j < ${#_TPL_DISPATCH_UNITS[@]}; j++ )); do done+="${_TPL_DISPATCH_UNITS[j]#*:} "; done
    [[ "$done" != " " ]] || return 0
    for (( j = from; j < ${#_TPL_DISPATCH_UNITS[@]}; j++ )); do
        id="${_TPL_DISPATCH_UNITS[j]#*:}"; v="_TPL_STAGE_REQUIRES_${id//-/_}"; ask=""
        for n in ${!v:-}; do [[ "$done" == *" $n "* ]] && ask+="$n "; done
        [[ -n "$ask" ]] || continue
        _stage_requires_unmet_v _STAGE_REQUIRES_UNMET "$sf" "${ask% }"
        if [[ -n "$_STAGE_REQUIRES_UNMET" ]]; then _STAGE_REQUIRES_HELD="$id"; return 1; fi
    done
    return 0
}
