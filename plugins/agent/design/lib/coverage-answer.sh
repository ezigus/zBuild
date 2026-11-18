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
# req_order, repo, base), into _DESIGN_UNCOVERED, _DESIGN_OUTSIDE,
# _DESIGN_STATUS_WRONG and _DESIGN_PART_WRONG.
# _DCOV_PROBLEM says what makes the answer unusable (an item with no line, a
# word that is not its kind's, a quote that is not there); _DCOV_LINES holds
# each item's lines and _DCOV_QUOTED the files each item's quotes name, for the
# answer kept per item (#2470, ADR-072 §4).
_dcov_parse() {
    local raw="$1" want=$'\n'"$2"$'\n'
    _DESIGN_UNCOVERED=(); _DESIGN_OUTSIDE=(); _DESIGN_STATUS_WRONG=(); _DCOV_PROBLEM=""
    _DESIGN_PART_WRONG=(); _DCOV_LINES=(); _DCOV_QUOTED=(); _DESIGN_NEW_OWNER=(); _DESIGN_REQ_NONE=()
    local -A seen=()
    local -a bad=()
    local l id rest word why quote instead w qp key reqs_asked=0 steps_asked=0 steps_seen=0
    [[ "$want" == *$'\nrequirements\n'* ]] && reqs_asked=1
    [[ "$want" == *$'\nsteps\n'* ]] && steps_asked=1
    while IFS= read -r l; do
        judge_reply_line_v l "$l"
        # #2555 (ADR-073): the design's steps, judged with the requirements.
        if [[ "$l" =~ ^Steps[*\`_]*:[[:space:]]*([a-z_-]+)(.*)$ ]]; then
            (( steps_asked )) || continue
            steps_seen=1; _DCOV_LINES["steps"]+="$l"$'\n'
            word="${BASH_REMATCH[1]}"; _dcov_why_quote "${BASH_REMATCH[2]}"
            case "$word" in
                ok) ;;
                new-owner)
                    if [[ -z "$quote" ]]; then bad+=("Steps has no QUOTE"); continue; fi
                    # The existing owner is in the code from before the change only.
                    judge_quote_check_v w "$quote" "" "${base:-$repo}" "${base:-$repo}" || { bad+=("Steps' quote $w in the code from before this change"); continue; }
                    judge_quote_path_v qp "$quote" "$repo" "$base"; [[ -n "$qp" ]] && _DCOV_QUOTED["steps"]+="$qp"$'\n'
                    _DESIGN_NEW_OWNER+=("${why:-something already owns this job}"$'\t'"$quote") ;;
                *) bad+=("Steps is ok or new-owner, not $word") ;;
            esac
            continue
        fi
        if [[ "$l" =~ ^([A-Za-z0-9]+-[0-9]+)[[:space:]]+(Title|Given|When|Then|And|Cleanup)([[:space:]]+[0-9]+)?[*\`_]*:[[:space:]]*([a-z_-]+)(.*)$ ]]; then
            id="${BASH_REMATCH[1]}"
            [[ -n "${first[$id]+x}" && "$want" == *$'\n'"$id"$'\n'* ]] || continue
            seen["$id"]=1; _DCOV_LINES["$id"]+="$l"$'\n'
            if [[ "${BASH_REMATCH[2]}" == Title ]]; then
                _dcov_title_line "$id" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
            else
                _dcov_part_line "$id" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]// /}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
            fi
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
                    # #2527 (ADR-070 §4): the requirement's words or the issue's, as
                    # issue-acceptance reads them; intake may have left some out.
                    judge_quote_check_v w "$quote" "${req_text[$id]}"$'\n'"${issue:-}" "$repo" "$base" || { bad+=("$id's quote $w"); continue; }
                    _DESIGN_UNCOVERED+=("$id: ${why:-no SPEC covers it} — $quote") ;;
                # #2565 (ADR-073 §5): nothing a test could observe settles it —
                # the issue's owner fixes it; design cannot.
                none)
                    if [[ -z "$why" ]]; then bad+=("$id: none has no WHY"); continue; fi
                    if [[ -z "$quote" ]]; then bad+=("$id has no QUOTE"); continue; fi
                    judge_quote_check_v w "$quote" "${req_text[$id]}"$'\n'"${issue:-}" "$repo" "$base" || { bad+=("$id's quote $w"); continue; }
                    _DESIGN_REQ_NONE+=("$id: $why") ;;
                *) bad+=("$id is a requirement: it is covered, uncovered or none, not $word") ;;
            esac
            continue
        fi
        case "$word" in
            ok) ;;
            # #2555 (ADR-073): every problem names the line it is about.
            *) bad+=("$id: a problem is written on the line it is about: $id Title: … or $id Then: …") ;;
        esac
    done <<< "$raw"
    local -a missing=()
    if (( reqs_asked )); then
        for id in ${req_order[@]+"${req_order[@]}"}; do [[ -n "${seen[$id]+x}" ]] || missing+=("$id"); done
    fi
    for id in ${ids[@]+"${ids[@]}"}; do
        [[ "$want" == *$'\n'"$id"$'\n'* && -z "${seen[$id]+x}" ]] && missing+=("$id")
    done
    (( steps_asked && ! steps_seen )) && missing+=("Steps")
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
        if [[ "$_dn_k" == requirements ]]; then _dn_req=1
        elif [[ "$_dn_k" == steps ]]; then _dn_out+="${_dn_out:+, }the Steps line"
        else _dn_out+="${_dn_out:+, }$_dn_k"; fi
    done <<< "$1"
    [[ -n "$_dn_req" ]] && _dn_out+="${_dn_out:+, }every requirement"
    printf '%s' "$_dn_out"
}

# _dcov_title_line <id> <verdict> <rest> — a problem with a SPEC's first line
# (#2555, ADR-073): not-asked or contradicts, its QUOTE from that line; status,
# its three facts and a QUOTE from the code. Read in _dcov_parse's scope.
_dcov_title_line() {
    local id="$1" word="$2" why quote instead w qp right=""
    _dcov_why_quote "$3"
    case "$word" in
        not-asked|contradicts|status|new-owner) ;;
        ok) return 0 ;;
        *) bad+=("$id Title is not-asked, contradicts or status, not $word"); return 0 ;;
    esac
    # #2543 (ADR-072, ADR-069): a status line gives three facts; the status they
    # give is worked out here, never taken from the judge.
    if [[ "$word" == status ]]; then
        _dcov_status_from_facts_v right "$3" || { bad+=("$id's status line $right"); return 0; }
        if [[ "$right" == "${st[$id]:-code}" ]]; then
            bad+=("$id's facts give [$right], its own status: a status line is only for a SPEC whose status is wrong"); return 0
        fi
    fi
    if [[ -z "$quote" ]]; then bad+=("$id Title has no QUOTE"); return 0; fi
    if [[ "$word" == new-owner ]]; then
        judge_quote_check_v w "$quote" "" "${base:-$repo}" "${base:-$repo}" || { bad+=("$id Title's quote $w in the code from before this change"); return 0; }
    else
        judge_quote_check_v w "$quote" "${text[$id]}" "$repo" "$base" || { bad+=("$id Title's quote $w"); return 0; }
    fi
    judge_quote_path_v qp "$quote" "$repo" "$base"; [[ -n "$qp" ]] && _DCOV_QUOTED["$id"]+="$qp"$'\n'
    case "$word" in
        not-asked)   _DESIGN_OUTSIDE+=("$id"$'\t'"${why:-the issue does not ask for it}"$'\t'"$quote") ;;
        contradicts) _DESIGN_OUTSIDE+=("$id"$'\t'"${why:-it contradicts the issue}"$'\t'"$quote"$'\t'contradicts) ;;
        new-owner)   _DESIGN_OUTSIDE+=("$id"$'\t'"${why:-something already owns this job}"$'\t'"$quote"$'\t'new-owner) ;;
        status)      _DESIGN_STATUS_WRONG+=("$id"$'\t'"$right"$'\t'"${st[$id]:-code}"$'\t'"${why:-its facts say so}"$'\t'"$quote") ;;
    esac
    return 0
}

# _dcov_status_from_facts_v <var> <rest> — the status a status line's three
# facts give (#2543): a document only → doc; else not already so → code; else
# work left → no-code; else done. rc 1, <var> saying why, when a fact is
# missing or not yes or no.
_dcov_status_from_facts_v() {
    local -n _dsf="$1"; local _dsf_r="$2" _dsf_re
    # judge_reply_line_v has made the head's borders spaces: either may part them.
    _dsf_re='DOC:[[:space:]]*([A-Za-z]+)[[:space:]|]*BEFORE:[[:space:]]*([A-Za-z]+)[[:space:]|]*WORK:[[:space:]]*([A-Za-z]+)'
    if ! [[ "$_dsf_r" =~ $_dsf_re ]]; then _dsf="has no DOC, BEFORE and WORK"; return 1; fi
    local _dsf_d="${BASH_REMATCH[1],,}" _dsf_b="${BASH_REMATCH[2],,}" _dsf_w="${BASH_REMATCH[3],,}" _dsf_x
    for _dsf_x in "$_dsf_d" "$_dsf_b" "$_dsf_w"; do
        [[ "$_dsf_x" == yes || "$_dsf_x" == no ]] || { _dsf="has a fact that is not yes or no: $_dsf_x"; return 1; }
    done
    if [[ "$_dsf_d" == yes ]]; then _dsf=doc
    elif [[ "$_dsf_b" == no ]]; then _dsf=code
    elif [[ "$_dsf_w" == yes ]]; then _dsf=no-code
    else _dsf="done"; fi
}

# _dcov_why_quote <rest> — a line's WHY, INSTEAD and QUOTE, into the caller's why,
# instead and quote.
_dcov_why_quote() {
    why=""; quote=""; instead=""
    if [[ "$1" == *"| WHY:"* ]]; then why="${1#*| WHY:}"; why="${why%%| QUOTE:*}"; why="${why%%| INSTEAD:*}"; fi
    if [[ "$1" == *"| INSTEAD:"* ]]; then
        instead="${1#*| INSTEAD:}"; instead="${instead%%| QUOTE:*}"
        instead="${instead#"${instead%%[![:space:]]*}"}"; instead="${instead%"${instead##*[![:space:]]}"}"
    fi
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
    local id="$1" pw="$2" num="$3" word="$4" why quote instead lab="" cand="" c kind
    _dcov_why_quote "$5"
    [[ "$word" == ok ]] && return 0
    case "$word" in
        not-asked|untestable|how|duplicate|contradicts) ;;
        status) bad+=("$id $pw: status is only on Title"); return 0 ;;
        *) bad+=("$id $pw is a line: it is ok, not-asked, untestable, how, contradicts or duplicate, not $word"); return 0 ;;
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
    # #2527: the quote as written; _judge_holds sets its quote marks aside.
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        _judge_holds "${ptext[$id $c]}" "$quote" && { lab="$c"; break; }
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
    # #2565 (ADR-073 §5): a refused wording says what would be accepted.
    if [[ "$word" == untestable || "$word" == how ]]; then
        [[ -n "$instead" ]] || { bad+=("$id $pw: $word has no INSTEAD — say what a test could observe after the When instead"); return 0; }
        why+=$'\x1f'"$instead"
    fi
    _DESIGN_PART_WRONG+=("$word"$'\t'"$id $lab"$'\t'"${why:-}"$'\t'"$quote")
    return 0
}

# _dcov_fix_v <var> <verdict> <why> <quote> — what to do about one thing the
# check found, as the bracket on the line it is about says it.
_dcov_fix_v() {
    local -n _dfx="$1"
    # #2565: an untestable or how <why> carries, after a unit separator, what a
    # test could observe instead.
    local _dfw="${3%%$'\x1f'*}" _dfi=""
    [[ "$3" == *$'\x1f'* ]] && _dfi="; a test could observe instead: ${3#*$'\x1f'}"
    case "$2" in
        untestable)    _dfx="$_dfw — say what a test can see the code do after the When$_dfi" ;;
        how)           _dfx="$_dfw — say the situation, the action, or what can be seen — not how it is built or how a test does it$_dfi" ;;
        contradicts)   _dfx="$3 — it cannot be true together with that; make them agree" ;;
        duplicate)     _dfx="$3 — another SPEC has this action; keep one of them" ;;
        not-asked)     _dfx="$3 — the issue does not ask for this; take it out, or make it what the issue asks" ;;
        new-owner)     _dfx="$3 — it builds a new owner where one exists: $4; build on it, or say why it cannot" ;;
        status:*)
            local _dfr="${2#status:}"; _dfr="${_dfr%%:*}"; local _dfo="${2##*:}"
            case "$_dfr" in
                done)    _dfx="$3: $4 — it is [done], not [$_dfo]: the code from before this change already does it; mark it [done], naming this evidence" ;;
                code)    _dfx="$3: $4 — it is [code], not [$_dfo]: the code from before this change does not do it" ;;
                no-code) _dfx="$3: $4 — it is [no-code], not [$_dfo]: the code already behaves so, and the work left changes no behaviour" ;;
                doc)     _dfx="$3: $4 — it is [doc], not [$_dfo]: write it on one line, saying what the doc must tell a reader" ;;
            esac ;;
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
    local _ox _oid _ow _oq _ok
    for x in ${_DESIGN_OUTSIDE[@]+"${_DESIGN_OUTSIDE[@]}"}; do
        IFS=$'\t' read -r _oid _ow _oq _ok <<< "$x"
        spec_level+=("${_ok:-not-asked}"$'\t'"$_oid"$'\t'"$_ow"$'\t'"$_oq")
    done
    for x in ${_DESIGN_NEW_OWNER[@]+"${_DESIGN_NEW_OWNER[@]}"}; do
        _DESIGN_COV_FINDINGS+=("Steps: the design's steps build a new owner where one exists: ${x%%$'\t'*} — ${x#*$'\t'} [FIX IN DESIGN: build on what exists, or say in the design why it cannot]")
    done
    local _sr _so
    for x in ${_DESIGN_STATUS_WRONG[@]+"${_DESIGN_STATUS_WRONG[@]}"}; do
        IFS=$'\t' read -r _id _sr _so _w _q <<< "$x"
        spec_level+=("status:$_sr:$_so"$'\t'"$_id"$'\t'"$_w"$'\t'"$_q")
    done
    for x in ${spec_level[@]+"${spec_level[@]}"}; do
        IFS=$'\t' read -r _v _id _w _q <<< "$x"
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
