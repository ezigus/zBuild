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

# A finding's id, as an answer names it (#2574, ADR-068 §5): a code and a number
# (item-ids.sh). An answer in the old form names it `<label> finding <n>`,
# still read during the change-over.
_ZB_FID_RE='[A-Z][A-Z0-9]{2,23}-[0-9]+'

# zb_answers_collect_v <array_var> <reply> — the reply's `ANSWER <id>: …` lines
# (and, from before #2574, `ANSWER <the finding as listed>: …`), without the
# word ANSWER, added to the array, each as `<id>: <answer>`; a finding answered
# twice keeps its latest answer.
zb_answers_collect_v() {
    local -n _zac="$1"
    local _zb_ans_line _zb_ans_a _zb_ans_k _zb_ans_i _joined _zb_ans_re='^[[:space:]>*`_-]*ANSWER[[:space:]]+(.+[[:space:]]finding[[:space:]]+[0-9]+[[:space:]]*(\([^)]*\))?[[:space:]]*:.*)$'
    local _zb_ans_kre='([^[:space:]]+[[:space:]]+finding[[:space:]]+[0-9]+)[[:space:]]*(\([^)]*\))?[[:space:]]*$'
    local _zb_ans_ire='^[[:space:]>*`_-]*ANSWER[[:space:]]+[*`_]*('"$_ZB_FID_RE"')[*`_]*[[:space:]]*(\([^)]*\))?[*`_]*[[:space:]]*:(.*)$'
    zb_reply_join_v _joined "${2:-}"
    while IFS= read -r _zb_ans_line; do
        if [[ "$_zb_ans_line" =~ $_zb_ans_ire ]]; then
            _zb_ans_k="${BASH_REMATCH[1]}"; _zb_ans_a="${BASH_REMATCH[1]}:${BASH_REMATCH[3]}"
        elif [[ "$_zb_ans_line" =~ $_zb_ans_re ]]; then
            _zb_ans_a="${BASH_REMATCH[1]}"
            _zb_ans_k="${_zb_ans_a%%:*}"
            # #2487: a stage that names the opening stage first ("review_lenses
            # finding lens-sre-code finding 2") still answers lens-sre-code finding 2;
            # #2491: so does one that copies the finding as listed, "(opened by …)" and all.
            if [[ "$_zb_ans_k" =~ $_zb_ans_kre ]]; then
                _zb_ans_a="${BASH_REMATCH[1]}:${_zb_ans_a#*:}"; _zb_ans_k="${BASH_REMATCH[1]}"
            fi
        else
            continue
        fi
        while [[ "$_zb_ans_a" == *[[:space:]] ]]; do _zb_ans_a="${_zb_ans_a%[[:space:]]}"; done
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
    local -n _zakv="$1"; local _zakv_re='^[^:]*:[[:space:]*_`]*(done|wrong|not[[:space:]]+mine)([^A-Za-z]|$)'
    _zakv=""
    [[ "${2,,}" =~ $_zakv_re ]] || return 0
    _zakv="${BASH_REMATCH[1]}"; [[ "$_zakv" == not* ]] && _zakv="not mine"
    return 0
}

# zb_answers_finish <arr> <prompt> <reply> [own-result] — a stage's answers to the findings
# its prompt showed it (ADR-068 §6), read from <reply> into <arr>. Sets
# _ZB_ANS_SHOWN (how many it was shown), _ZB_ANS_MISSING (each not answered,
# one per line) and _ZB_ANS_FINDING (each shown finding's text, by its id: what
# travels with the answer, #2574). Nothing is asked again (#2491): a finding
# with no answer stays open, and is shown again next round. A finding is shown
# as `- <id> (opened by …): …`, or, written before ids, `- <label> finding <n>
# (opened by …): …` (stage-previous-work.sh); its lines after the first are
# indented. #2611 (ADR-068 §6): a finding shown and not answered keeps the
# answer [own-result] (the stage's own latest result) gave it, when that result
# was written in this run (after ZBUILD_RUN_START_MARKER) and the finding is the
# one it answered, word for word (data.answer_findings) — still to be judged.
_ZB_ANS_SHOWN=0 _ZB_ANS_MISSING=""
declare -gA _ZB_ANS_FINDING=()
zb_answers_finish() {
    local -n _zaf="$1"
    local _zaf_l _zaf_k _zaf_a _zaf_kind _zaf_last=""
    local _zaf_re='^-[[:space:]]+('"$_ZB_FID_RE"'|[^[:space:]]+[[:space:]]+finding[[:space:]]+[0-9]+)[[:space:]]+\(opened[[:space:]]by[^)]*\):[[:space:]]?(.*)$'
    local -A _zaf_seen=() _zaf_ok=()
    _ZB_ANS_SHOWN=0 _ZB_ANS_MISSING=""; _ZB_ANS_FINDING=()
    zb_answers_collect_v _zaf "${3:-}"
    for _zaf_a in ${_zaf[@]+"${_zaf[@]}"}; do
        zb_answer_kind_v _zaf_kind "$_zaf_a"; [[ -n "$_zaf_kind" ]] && _zaf_ok["${_zaf_a%%:*}"]=1
    done
    while IFS= read -r _zaf_l; do
        if [[ "$_zaf_l" =~ $_zaf_re ]]; then
            _zaf_k="${BASH_REMATCH[1]}"; _zaf_last=""
            [[ -n "${_zaf_seen[$_zaf_k]+x}" ]] && continue
            _zaf_seen["$_zaf_k"]=1; _ZB_ANS_SHOWN=$((_ZB_ANS_SHOWN + 1)); _zaf_last="$_zaf_k"
            _ZB_ANS_FINDING["$_zaf_k"]="${BASH_REMATCH[2]}"
            [[ -n "${_zaf_ok[$_zaf_k]+x}" ]] || _ZB_ANS_MISSING+="${_ZB_ANS_MISSING:+$'\n'}$_zaf_k"
        elif [[ -n "$_zaf_last" && "$_zaf_l" == "    "* ]]; then
            _ZB_ANS_FINDING["$_zaf_last"]+=$'\n'"${_zaf_l#    }"
        else
            _zaf_last=""
        fi
    done <<< "${2:-}"
    [[ -n "$_ZB_ANS_MISSING" ]] && _zb_answers_carry "$1" "${4:-}"
    return 0
}

# _zb_answers_carry <arr> <own-result> — the carry zb_answers_finish describes:
# one jq over the stage's own result, only when it is from this run.
_zb_answers_carry() {
    local -n _zc="$1"; local _f="${2:-}" _m="${ZBUILD_RUN_START_MARKER:-}" _rows _id _a _t _k _left=""
    [[ -n "$_f" && -s "$_f" && -n "$_m" && -e "$_m" && "$_f" -nt "$_m" ]] || return 0
    _rows="$(jq -r '(.data.answer_findings // {}) as $af | (.data.answers // [])[]? | strings
        | (split(":")[0]) as $id | select($af[$id] != null)
        | [$id, ., $af[$id]] | map(gsub("[\t\n\r\u001f]"; " ")) | join("\u001f")' "$_f" 2>/dev/null)" || return 0
    [[ -n "$_rows" ]] || return 0
    local -A _prior=() _ptext=()
    # Joined by US, not @tsv: @tsv escapes a backslash, and the text must match word for word.
    while IFS=$'\x1f' read -r _id _a _t; do _prior["$_id"]="$_a"; _ptext["$_id"]="$_t"; done <<< "$_rows"
    while IFS= read -r _id; do
        [[ -n "$_id" ]] || continue
        _t="${_ZB_ANS_FINDING[$_id]:-}"; _t="${_t//[$'\t\n\r']/ }"
        _k=""; [[ -n "${_prior[$_id]+x}" ]] && zb_answer_kind_v _k "${_prior[$_id]}"
        if [[ -n "$_k" && "${_ptext[$_id]}" == "$_t" ]]; then _zc+=("${_prior[$_id]}")
        else _left+="${_left:+$'\n'}$_id"; fi
    done <<< "$_ZB_ANS_MISSING"
    _ZB_ANS_MISSING="$_left"
}

# _zb_ans_json_str_v <var> <text> — <text> as a JSON string, by the shell.
_zb_ans_json_str_v() {
    local -n _zajs="$1"; local LC_ALL=C _zajs_s="$2"
    _zajs_s="${_zajs_s//\\/\\\\}"; _zajs_s="${_zajs_s//\"/\\\"}"
    _zajs_s="${_zajs_s//$'\n'/\\n}"; _zajs_s="${_zajs_s//$'\r'/\\r}"; _zajs_s="${_zajs_s//$'\t'/\\t}"
    _zajs_s="${_zajs_s//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']/ }"
    _zajs="\"$_zajs_s\""
}

# zb_answers_findings_json_v <var> <arr> — the text of each finding an answer
# of <arr> answers, as the stage was shown it (zb_answers_finish), as a JSON
# object by id: what a stage keeps beside its answers (data.answer_findings),
# so the finding travels with the answer (#2574). "{}" when none is known; no
# process.
zb_answers_findings_json_v() {
    local -n _zafj="$1" _zafj_a="$2"; local _zafj_x _zafj_k _zafj_j _zafj_v _zafj_out=""
    local -A _zafj_seen=()
    for _zafj_x in ${_zafj_a[@]+"${_zafj_a[@]}"}; do
        _zafj_k="${_zafj_x%%:*}"
        [[ -n "${_ZB_ANS_FINDING[$_zafj_k]+x}" && -z "${_zafj_seen[$_zafj_k]+x}" ]] || continue
        _zafj_seen["$_zafj_k"]=1
        _zb_ans_json_str_v _zafj_j "$_zafj_k"; _zb_ans_json_str_v _zafj_v "${_ZB_ANS_FINDING[$_zafj_k]}"
        _zafj_out+="${_zafj_out:+,}$_zafj_j:$_zafj_v"
    done
    _zafj="{$_zafj_out}"
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

# zb_not_mine_target_v <var> <answer text> — which stage a "not mine" answer
# says can fix the finding (#2599, ADR-068 §6): code, test or design; empty when
# it says none. A stage it names ("design must …", "the code must change") wins
# over any file it names; else a file: one in the test folders is test's, any
# other path with a dot is code's; else a stage named in passing. In any case.
# Needs test-paths.sh. No process.
zb_not_mine_target_v() {
    local -n _znm="$1"; local _t="${2:-}" _w _x _had=0
    local -a _ws=()
    _znm=""
    shopt -q nocasematch && _had=1
    shopt -s nocasematch
    local _re='(^|[^a-z])(the[[:space:]]+)?(code|build|tests?|test[-[:space:]]?author|design)([[:space:]]+stage)?[[:space:]]+must([^a-z]|$)'
    if [[ "$_t" =~ $_re ]]; then
        case "${BASH_REMATCH[3]}" in
            code|build) _znm=code ;; design) _znm=design ;; *) _znm="test" ;;
        esac
    fi
    if [[ -z "$_znm" ]]; then
        read -ra _ws <<< "$_t"   # no glob: a word like tests/* stays a word
        for _w in ${_ws[@]+"${_ws[@]}"}; do
            _x="${_w//[\`\'\"(),;]/}"; _x="${_x%.}"; _x="${_x%:}"; _x="${_x#./}"
            [[ "$_x" == */* ]] || continue
            if declare -F zb_is_test_path >/dev/null 2>&1 && zb_is_test_path "$_x"; then _znm="test"; break; fi
            [[ "$_x" == *.* ]] && { _znm=code; break; }
        done
    fi
    if [[ -z "$_znm" ]]; then
        if [[ "$_t" =~ test[-[:space:]]?author ]]; then _znm="test"
        elif [[ "$_t" =~ (^|[^a-z])(the[[:space:]]+code|code[[:space:]]+stage|build[[:space:]]+stage)([^a-z]|$) ]]; then _znm=code
        elif [[ "$_t" =~ (^|[^a-z])design([^a-z]|$) ]]; then _znm=design; fi
    fi
    (( _had )) || shopt -u nocasematch
    return 0
}
