#!/usr/bin/env bash
# scripts/lib/stage-answers.sh — a stage's answers to the findings it is given
# (ADR-068 §6): read from its reply, each done, wrong or not mine; one it did
# not give stays open; and the lines its summary shows about them. Sourced by
# judge.sh, whose judges read the `wrong` ones back (ADR-072 §5).
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_STAGE_ANSWERS_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_ANSWERS_LOADED=1
# shellcheck source=reply-units.sh
source "${BASH_SOURCE[0]%/*}/reply-units.sh"

# zb_answers_collect_v <array_var> <reply> — the reply's `ANSWER <the finding
# as listed>: …` lines, without the word ANSWER, added to the array; a finding
# answered twice keeps its latest answer.
zb_answers_collect_v() {
    local -n _zac="$1"
    local _zb_ans_line _zb_ans_a _zb_ans_k _zb_ans_i _joined _zb_ans_re='^[[:space:]>*`_-]*ANSWER[[:space:]]+(.+[[:space:]]finding[[:space:]]+[0-9]+[[:space:]]*(\([^)]*\))?[[:space:]]*:.*)$'
    local _zb_ans_kre='([^[:space:]]+[[:space:]]+finding[[:space:]]+[0-9]+)[[:space:]]*(\([^)]*\))?[[:space:]]*$'
    zb_reply_join_v _joined "${2:-}"
    while IFS= read -r _zb_ans_line; do
        [[ "$_zb_ans_line" =~ $_zb_ans_re ]] || continue
        _zb_ans_a="${BASH_REMATCH[1]}"
        while [[ "$_zb_ans_a" == *[[:space:]] ]]; do _zb_ans_a="${_zb_ans_a%[[:space:]]}"; done
        _zb_ans_k="${_zb_ans_a%%:*}"
        # #2487: a stage that names the opening stage first ("review_lenses
        # finding lens-sre-code finding 2") still answers lens-sre-code finding 2;
        # #2491: so does one that copies the finding as listed, "(opened by …)" and all.
        if [[ "$_zb_ans_k" =~ $_zb_ans_kre ]]; then
            _zb_ans_a="${BASH_REMATCH[1]}:${_zb_ans_a#*:}"; _zb_ans_k="${BASH_REMATCH[1]}"
        fi
        for _zb_ans_i in "${!_zac[@]}"; do
            [[ "${_zac[_zb_ans_i]%%:*}" == "$_zb_ans_k" ]] && unset '_zac[_zb_ans_i]'
        done
        _zac=(${_zac[@]+"${_zac[@]}"})
        _zac+=("$_zb_ans_a")
    done <<< "$_joined"
    return 0
}

# zb_answer_kind_v <var> <answer> — what an answer says (ADR-068 §6): done (the
# stage changed something for it), wrong (it does not hold), not mine (the
# stage's job cannot fix it); empty when it is none of them, which is no answer.
zb_answer_kind_v() {
    local -n _zakv="$1"; local _zakv_re='^[^:]*finding[[:space:]]+[0-9]+[[:space:]]*:[[:space:]*_`]*(done|wrong|not[[:space:]]+mine)([^A-Za-z]|$)'
    _zakv=""
    [[ "${2,,}" =~ $_zakv_re ]] || return 0
    _zakv="${BASH_REMATCH[1]}"; [[ "$_zakv" == not* ]] && _zakv="not mine"
    return 0
}

# zb_answers_finish <arr> <prompt> <reply> — a stage's answers to the findings
# its prompt showed it (ADR-068 §6), read from <reply> into <arr>. Sets
# _ZB_ANS_SHOWN (how many it was shown) and _ZB_ANS_MISSING (each not answered,
# one per line). Nothing is asked again (#2491): a finding with no answer stays
# open, and is shown again next round. A finding is shown as
# `- <label> finding <n> (opened by …): …` (stage-previous-work.sh).
_ZB_ANS_SHOWN=0 _ZB_ANS_MISSING=""
zb_answers_finish() {
    local -n _zaf="$1"
    local _zaf_l _zaf_k _zaf_a _zaf_kind
    local _zaf_re='^-[[:space:]]+([^[:space:]]+[[:space:]]+finding[[:space:]]+[0-9]+)[[:space:]]+\(opened[[:space:]]by'
    local -A _zaf_seen=() _zaf_ok=()
    _ZB_ANS_SHOWN=0 _ZB_ANS_MISSING=""
    zb_answers_collect_v _zaf "${3:-}"
    for _zaf_a in ${_zaf[@]+"${_zaf[@]}"}; do
        zb_answer_kind_v _zaf_kind "$_zaf_a"; [[ -n "$_zaf_kind" ]] && _zaf_ok["${_zaf_a%%:*}"]=1
    done
    while IFS= read -r _zaf_l; do
        [[ "$_zaf_l" =~ $_zaf_re ]] || continue
        _zaf_k="${BASH_REMATCH[1]}"
        [[ -n "${_zaf_seen[$_zaf_k]+x}" ]] && continue
        _zaf_seen["$_zaf_k"]=1; _ZB_ANS_SHOWN=$((_ZB_ANS_SHOWN + 1))
        [[ -n "${_zaf_ok[$_zaf_k]+x}" ]] || _ZB_ANS_MISSING+="${_ZB_ANS_MISSING:+$'\n'}$_zaf_k"
    done <<< "${2:-}"
    return 0
}

# zb_answers_summary_v <var> <arr> — the lines a stage's summary shows about the
# findings it was given (after zb_answers_finish): each answer, each finding
# left unanswered, or that no finding was open.
zb_answers_summary_v() {
    local -n _zas="$1" _zas_a="$2"; local _zas_x
    _zas=""
    for _zas_x in ${_zas_a[@]+"${_zas_a[@]}"}; do _zas+="${_zas:+$'\n'}- answered: $_zas_x"; done
    while IFS= read -r _zas_x; do [[ -n "$_zas_x" ]] && _zas+="${_zas:+$'\n'}- not answered: $_zas_x"; done <<< "${_ZB_ANS_MISSING:-}"
    [[ -z "$_zas" && "${_ZB_ANS_SHOWN:-0}" -eq 0 ]] && _zas="- no finding was open for it"
    return 0
}
