#!/usr/bin/env bash
# plugins/agent/design/lib/coverage-answer.sh — reading the coverage check's
# answer, and writing what it found as design's findings (#2470, ADR-073 §5,
# ADR-072 §3 §4). Split from coverage.sh; every function here runs inside
# _design_coverage and reads the SPECs it read (ids, first, labs, pword, ptext).
#
# Sourced library: no set -euo pipefail.
# shellcheck disable=SC2154  # the SPECs, requirements and paths are _design_coverage's

[[ -n "${_ZBUILD_DESIGN_COVERAGE_ANSWER_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_COVERAGE_ANSWER_LOADED=1

# _dcov_parse <reply> <want> — the reply's lines for the items in <want> (SPEC
# ids, and `requirements` when requirement coverage was asked), read in
# _design_coverage's scope (ids, first, text, st, labs, pword, ptext, req_text,
# req_order, scope, repo, base), into _DESIGN_UNCOVERED, _DESIGN_OUTSIDE,
# _DESIGN_DONE_WRONG, _DESIGN_NEEDS_CLEANUP and _DESIGN_PART_WRONG.
# _DCOV_PROBLEM says what makes the answer unusable (an item with no line, a
# word that is not its kind's, a quote that is not there); _DCOV_LINES holds
# each item's lines and _DCOV_QUOTED the files each item's quotes name, for the
# answer kept per item (#2470, ADR-072 §4).
_dcov_parse() {
    local raw="$1" want=$'\n'"$2"$'\n'
    _DESIGN_UNCOVERED=(); _DESIGN_OUTSIDE=(); _DESIGN_DONE_WRONG=(); _DCOV_PROBLEM=""
    _DESIGN_PART_WRONG=(); _DESIGN_NEEDS_CLEANUP=(); _DCOV_LINES=(); _DCOV_QUOTED=()
    local -A seen=()
    local -a bad=()
    local l id rest word why quote w qp key reqs_asked=0
    [[ "$want" == *$'\nrequirements\n'* ]] && reqs_asked=1
    while IFS= read -r l; do
        judge_reply_line_v l "$l"
        if [[ "$l" =~ ^SCOPE:[[:space:]]*(.*)$ ]]; then
            (( reqs_asked )) || continue
            rest="${BASH_REMATCH[1]}"; w="${rest%%|*}"; w="${w%"${w##*[![:space:]]}"}"
            why=""; [[ "$rest" == *"| WHY:"* ]] && { why="${rest#*| WHY:}"; why="${why#"${why%%[![:space:]]*}"}"; }
            if [[ $'\n'"$scope"$'\n' == *$'\n'"$w"$'\n'* ]]; then
                _DESIGN_OUTSIDE+=("SCOPE"$'\t'"$w"$'\t'"${why:-the issue does not ask for it}")
                _DCOV_LINES["requirements"]+="$l"$'\n'
            else
                bad+=("SCOPE names $w, which is not in the design's scope")
            fi
            continue
        fi
        if [[ "$l" =~ ^([A-Za-z0-9]+-[0-9]+)[[:space:]]+(Given|When|Then|And|Cleanup)([[:space:]]+[0-9]+)?[*\`_]*:[[:space:]]*([a-z_]+)(.*)$ ]]; then
            id="${BASH_REMATCH[1]}"
            [[ -n "${first[$id]+x}" && "$want" == *$'\n'"$id"$'\n'* ]] || continue
            seen["$id"]=1; _DCOV_LINES["$id"]+="$l"$'\n'
            _dcov_part_line "$id" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]// /}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
            continue
        fi
        [[ "$l" =~ ^([A-Za-z0-9]+-[0-9]+)[*\`_]*:[[:space:]]*([a-z_]+)(.*)$ ]] || continue
        id="${BASH_REMATCH[1]}"; word="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
        if [[ -n "${req_text[$id]+x}" ]]; then (( reqs_asked )) || continue; key=requirements
        elif [[ -n "${first[$id]+x}" && "$want" == *$'\n'"$id"$'\n'* ]]; then key="$id"
        else continue; fi
        seen["$id"]=1; _DCOV_LINES["$key"]+="$l"$'\n'
        _dcov_why_quote "$rest"
        if [[ "$key" == requirements ]]; then
            case "$word" in
                covered) continue ;;
                uncovered)
                    if [[ -z "$quote" ]]; then bad+=("$id has no QUOTE"); continue; fi
                    judge_quote_check_v w "$quote" "${req_text[$id]}" "$repo" "$base" || { bad+=("$id's quote $w"); continue; }
                    _DESIGN_UNCOVERED+=("$id: ${why:-no SPEC covers it} — $quote") ;;
                *) bad+=("$id is a requirement: it is covered or uncovered, not $word") ;;
            esac
            continue
        fi
        case "$word" in
            ok) ;;
            needs_cleanup)
                if [[ -z "$quote" ]]; then bad+=("$id has no QUOTE"); continue; fi
                local _dpw="${text[$id]}" _dpl
                while IFS= read -r _dpl; do [[ -n "$_dpl" ]] && _dpw+=$'\n'"${ptext[$id $_dpl]}"; done <<< "${labs[$id]}"
                judge_quote_check_v w "$quote" "$_dpw" "$repo" "$base" || { bad+=("$id's quote $w"); continue; }
                _DESIGN_NEEDS_CLEANUP+=("$id"$'\t'"${why:-it leaves something behind}"$'\t'"$quote") ;;
            outside|done_wrong)
                if [[ "$word" == done_wrong && "${st[$id]}" != "done" ]]; then
                    bad+=("$id is not marked [done]: done_wrong is only for a SPEC that is"); continue
                fi
                if [[ -z "$quote" ]]; then bad+=("$id has no QUOTE"); continue; fi
                judge_quote_check_v w "$quote" "${text[$id]}" "$repo" "$base" || { bad+=("$id's quote $w"); continue; }
                judge_quote_path_v qp "$quote" "$repo" "$base"; [[ -n "$qp" ]] && _DCOV_QUOTED["$id"]+="$qp"$'\n'
                if [[ "$word" == outside ]]; then _DESIGN_OUTSIDE+=("$id"$'\t'"${why:-the issue does not ask for it}"$'\t'"$quote")
                else _DESIGN_DONE_WRONG+=("$id"$'\t'"${why:-the code does not do it}"$'\t'"$quote"); fi ;;
            *) bad+=("$id is a SPEC: it is ok, outside, done_wrong or needs_cleanup, not $word") ;;
        esac
    done <<< "$raw"
    local -a missing=()
    if (( reqs_asked )); then
        for id in ${req_order[@]+"${req_order[@]}"}; do [[ -n "${seen[$id]+x}" ]] || missing+=("$id"); done
    fi
    for id in ${ids[@]+"${ids[@]}"}; do
        [[ "$want" == *$'\n'"$id"$'\n'* && -z "${seen[$id]+x}" ]] && missing+=("$id")
    done
    [[ ${#missing[@]} -gt 0 ]] && bad=("it has no line for ${missing[*]}" ${bad[@]+"${bad[@]}"})
    if [[ ${#bad[@]} -gt 0 ]]; then
        local IFS=';'; _DCOV_PROBLEM="${bad[*]}"; _DCOV_PROBLEM="${_DCOV_PROBLEM//;/; }"
    fi
    return 0
}

# _dcov_take <reply> <need> — each item of <need> (one per line) whose lines in
# <reply> can be used, into the caller's got (its lines) and gotq (the files its
# quotes name), and out of need; _DCOV_PROBLEM says what is wrong with the rest
# (#2472, ADR-072 §3: a bad line costs only its own item).
# shellcheck disable=SC2034  # got, gotq and need are _design_coverage's
_dcov_take() {
    local _dt_reply="$1" _dt_k _dt_left="" _dt_prob=""
    _dcov_parse "$_dt_reply" "$2"
    if [[ -z "$_DCOV_PROBLEM" ]]; then
        while IFS= read -r _dt_k; do
            [[ -n "$_dt_k" ]] || continue
            got["$_dt_k"]="${_DCOV_LINES[$_dt_k]:-}"; gotq["$_dt_k"]="${_DCOV_QUOTED[$_dt_k]:-}"
        done <<< "$2"
        need=""
        return 0
    fi
    _dt_prob="$_DCOV_PROBLEM"
    while IFS= read -r _dt_k; do
        [[ -n "$_dt_k" ]] || continue
        _dcov_parse "$_dt_reply" "$_dt_k"
        if [[ -z "$_DCOV_PROBLEM" ]]; then
            got["$_dt_k"]="${_DCOV_LINES[$_dt_k]:-}"; gotq["$_dt_k"]="${_DCOV_QUOTED[$_dt_k]:-}"
        else
            _dt_left+="$_dt_k"$'\n'
        fi
    done <<< "$2"
    need="$_dt_left"
    _DCOV_PROBLEM="$_dt_prob"
    return 0
}

# _dcov_need_names <need> — the items still to answer, as a judge reads them.
_dcov_need_names() {
    local _dn_k _dn_out="" _dn_req=""
    while IFS= read -r _dn_k; do
        [[ -n "$_dn_k" ]] || continue
        if [[ "$_dn_k" == requirements ]]; then _dn_req=1; else _dn_out+="${_dn_out:+, }$_dn_k"; fi
    done <<< "$1"
    [[ -n "$_dn_req" ]] && _dn_out+="${_dn_out:+, }every requirement"
    printf '%s' "$_dn_out"
}

# _dcov_why_quote <rest> — a line's WHY and QUOTE, into the caller's why and quote.
_dcov_why_quote() {
    why=""; quote=""
    if [[ "$1" == *"| WHY:"* ]]; then why="${1#*| WHY:}"; why="${why%%| QUOTE:*}"; fi
    why="${why#"${why%%[![:space:]]*}"}"; why="${why%"${why##*[![:space:]]}"}"
    [[ "$1" == *"| QUOTE:"* ]] && { quote="${1#*| QUOTE:}"; quote="${quote#"${quote%%[![:space:]]*}"}"; quote="${quote%"${quote##*[![:space:]]}"}"; }
    return 0
}

# _dcov_part_line <id> <word> <number> <verdict> <rest> — one part's line of the
# answer, read in _dcov_parse's scope. The part is named by the word its line
# starts with, as design wrote it; the quote, its own words, picks which line
# when the SPEC has several (#2470, ADR-073 §5). An old label with a number
# (Then 2) is still read.
_dcov_part_line() {
    local id="$1" pw="$2" num="$3" word="$4" why quote lab="" cand="" c kind
    _dcov_why_quote "$5"
    [[ "$word" == ok ]] && return 0
    case "$word" in
        untestable|how|duplicate|contradicts) ;;
        *) bad+=("$id $pw is a part: it is ok, untestable, how, contradicts or duplicate, not $word"); return 0 ;;
    esac
    if [[ -n "$num" && "$pw" != And && -n "${ptext[$id $pw $num]+x}" ]]; then
        cand="$pw $num"
    else
        while IFS= read -r c; do
            [[ -n "$c" ]] || continue
            kind="${c%% *}"
            if [[ "$pw" == And ]]; then [[ "${pword[$id $c]}" == And ]] && cand+="$c"$'\n'
            elif [[ "$kind" == "$pw" ]]; then cand+="$c"$'\n'; fi
        done <<< "${labs[$id]}"
    fi
    if [[ -z "$cand" ]]; then bad+=("$id has no $pw line"); return 0; fi
    if [[ -z "$quote" ]]; then bad+=("$id $pw has no QUOTE"); return 0; fi
    if [[ ! "$quote" =~ ^\"(.*)\"$ ]]; then bad+=("$id $pw's quote is not a quote: write \"<that part's own words>\""); return 0; fi
    local q="${BASH_REMATCH[1]}"
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        _judge_holds "${ptext[$id $c]}" "$q" && { lab="$c"; break; }
    done <<< "$cand"
    if [[ -z "$lab" ]]; then
        case "$pw" in
            When) bad+=("$id When's quote is not in its When line") ;;
            And)  bad+=("$id And's quote is not in any of its And lines") ;;
            *)    bad+=("$id $pw's quote is not in any of its $pw lines") ;;
        esac
        return 0
    fi
    kind="${lab%% *}"
    [[ "$word" == untestable && "$kind" != Then ]] && { bad+=("$id $pw: untestable is only for a Then, or an And under one"); return 0; }
    [[ "$word" == duplicate && "$kind" != When ]] && { bad+=("$id $pw: duplicate is only for the When"); return 0; }
    _DESIGN_PART_WRONG+=("$word"$'\t'"$id $lab"$'\t'"${why:-}"$'\t'"$quote")
    return 0
}

# _dcov_fix_v <var> <verdict> <why> <quote> — what to do about one thing the
# check found, as the bracket on the line it is about says it.
_dcov_fix_v() {
    local -n _dfx="$1"
    case "$2" in
        untestable)    _dfx="$3 — say what a test can see the code do after the When" ;;
        how)           _dfx="$3 — say what someone could see happen, not how it is built" ;;
        contradicts)   _dfx="$3 — it cannot be true together with that; make them agree" ;;
        duplicate)     _dfx="$3 — another SPEC has this action; keep one of them" ;;
        needs_cleanup) _dfx="$3 — add a Cleanup: line saying what must be true again after the test" ;;
        outside)       _dfx="$3 — the issue does not ask for this; take it out, or make it what the issue asks" ;;
        done_wrong)    _dfx="$3: $4 — the code from before this change does not do it; mark it [code], or name evidence that shows it" ;;
    esac
}

# _dcov_findings_build — the check's answer as design's findings, into
# _DESIGN_COV_FINDINGS, in _design_coverage's scope. #2470 (ADR-073 §5): a SPEC
# with something to fix is one finding, shown whole — its first line and each
# part as written, the lines joined by a record separator — with
# [FIX IN DESIGN: …] on exactly the lines to fix. A SPEC that passed is not shown.
_dcov_findings_build() {
    _DESIGN_COV_FINDINGS=()
    local x _v _k _w _q _id _lab _fix out pl
    local -A on_first=() on_part=() count=()
    for x in ${_DESIGN_UNCOVERED[@]+"${_DESIGN_UNCOVERED[@]}"}; do
        _DESIGN_COV_FINDINGS+=("${x%%: *} is not covered: ${x#*: } [FIX IN DESIGN: add or widen a SPEC so it covers this]")
    done
    local -a spec_level=()
    for x in ${_DESIGN_OUTSIDE[@]+"${_DESIGN_OUTSIDE[@]}"}; do spec_level+=("outside"$'\t'"$x"); done
    for x in ${_DESIGN_DONE_WRONG[@]+"${_DESIGN_DONE_WRONG[@]}"}; do spec_level+=("done_wrong"$'\t'"$x"); done
    for x in ${_DESIGN_NEEDS_CLEANUP[@]+"${_DESIGN_NEEDS_CLEANUP[@]}"}; do spec_level+=("needs_cleanup"$'\t'"$x"); done
    for x in ${spec_level[@]+"${spec_level[@]}"}; do
        IFS=$'\t' read -r _v _id _w _q <<< "$x"
        if [[ "$_id" == SCOPE ]]; then
            _DESIGN_COV_FINDINGS+=("SCOPE $_w: $_q [FIX IN DESIGN: the issue does not ask for it; take it out of the scope]")
            continue
        fi
        _dcov_fix_v _fix "$_v" "$_w" "$_q"
        on_first["$_id"]+=" [FIX IN DESIGN: $_fix]"; count["$_id"]=$(( ${count[$_id]:-0} + 1 ))
    done
    for x in ${_DESIGN_PART_WRONG[@]+"${_DESIGN_PART_WRONG[@]}"}; do
        IFS=$'\t' read -r _v _k _w _q <<< "$x"
        _id="${_k%% *}"
        _dcov_fix_v _fix "$_v" "$_w" "$_q"
        on_part["$_k"]+=" [FIX IN DESIGN: $_fix]"; count["$_id"]=$(( ${count[$_id]:-0} + 1 ))
    done
    for _id in ${ids[@]+"${ids[@]}"}; do
        [[ -n "${count[$_id]+x}" ]] || continue
        pl=s; (( count[$_id] == 1 )) && pl=""
        out="$_id: ${count[$_id]} part$pl to fix"$'\x1e'"${first[$_id]}${on_first[$_id]:-}"
        while IFS= read -r _lab; do
            [[ -n "$_lab" ]] || continue
            out+=$'\x1e'"  ${pword[$_id $_lab]}: ${ptext[$_id $_lab]}${on_part[$_id $_lab]:-}"
        done <<< "${labs[$_id]}"
        _DESIGN_COV_FINDINGS+=("$out")
    done
    return 0
}

# _design_coverage_findings — the check's findings, one per line.
_design_coverage_findings() {
    local x
    for x in ${_DESIGN_COV_FINDINGS[@]+"${_DESIGN_COV_FINDINGS[@]}"}; do printf '%s\n' "$x"; done
    return 0
}
