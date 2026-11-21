#!/usr/bin/env bash
# scripts/lib/judge-held.sh — a check held to its earlier findings (#2569,
# ADR-072 §5): every answer a stage gives one of its findings, the finding it
# answers, and what the check is shown of them. Split from judge.sh (under 500
# lines); judge.sh sources it, and its callers source judge.sh.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_JUDGE_HELD_LOADED:-}" ]] && return 0
_ZBUILD_JUDGE_HELD_LOADED=1

# ─── Answers to a check's findings (§5, ADR-068 §6) ──────────────────────────

# judge_answers_to <artifact_dir> <label|code>... — every answer a stage keeps in
# its result (data.answers) to a finding labelled <label> (the form before
# #2574) or with an id of <code> (#2574), one per line: done, wrong or not
# mine, each goes back to the finding's judge (#2569, ADR-072 §5), which is
# held to its finding.
judge_answers_to() { local _jat=""; judge_answers_to_v _jat "$@"; [[ -n "$_jat" ]] && printf '%s\n' "$_jat"; return 0; }
# judge_answers_to_v <var> <artifact_dir> <label|code>... — the same into <var>.
# _JUDGE_ANSWER_FINDING gets the text of each answered finding the answering
# stage kept with its answers (data.answer_findings): the finding travels with
# the answer (#2574).
# _JUDGE_ANSWER_FROM gets the result file each answer is in: the answering
# stage (#2574: a not mine hands its part on only through that stage's outputs).
declare -gA _JUDGE_ANSWER_FINDING=() _JUDGE_ANSWER_FROM=()
judge_answers_to_v() {
    local -n _jatv="$1"; shift
    _jatv=""; _JUDGE_ANSWER_FINDING=(); _JUDGE_ANSWER_FROM=()
    local dir="${1:+${1%/}}"; shift
    [[ -d "$dir" && $# -gt 0 ]] || return 0
    local re="" cre="" l
    for l in "$@"; do
        if [[ "$l" =~ ^[A-Z][A-Z0-9]{2,5}$ ]]; then cre+="${cre:+|}$l"
        else re+="${re:+|}${l//[^A-Za-z0-9_-]/.}"; fi
    done
    local key="(${re:+($re) finding [0-9]+}${re:+${cre:+|}}${cre:+($cre)-[0-9]+})"
    local -a files=()
    local f _jat_body _jat_t _jat_k _jat_x
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        # read, not $(<): no process for a file with no answers (ADR-065 §5).
        _jat_body=""; IFS= read -r -d '' _jat_body < "$f" || true
        [[ "$_jat_body" == *'"answers"'* ]] && files+=("$f")
    done
    [[ ${#files[@]} -gt 0 ]] || return 0
    while IFS=$'\t' read -r _jat_t _jat_k _jat_x; do
        case "$_jat_t" in
            A) _jatv+="${_jatv:+$'\n'}$_jat_x"; _JUDGE_ANSWER_FROM["${_jat_x%%:*}"]="$_jat_k" ;;
            T) [[ -n "$_jat_k" ]] && _JUDGE_ANSWER_FINDING["$_jat_k"]="${_jat_x//$'\x1e'/$'\n'}" ;;
        esac
    done < <(jq -r --arg re "^${key}[[:space:]]*:[[:space:]*_\`]*(done|wrong|not[[:space:]]+mine)([^A-Za-z]|$)" --arg kre "^${key}$" \
        '((.data.answers // [])[]? | strings | select(test($re; "i")) | "A\t\(input_filename)\t" + gsub("[\t\r\n]"; " ")),
         ((.data.answer_findings // {}) | objects | to_entries[] | select(.key | test($kre; "i"))
          | "T\t\(.key)\t\(.value | tostring | gsub("\t"; " ") | gsub("\r?\n"; "\u001e"))")' "${files[@]}" 2>/dev/null)
    return 0
}

# judge_answered_findings_v <out_assoc> <answers> <label>=<result_json>... —
# each answer of <answers> ("<id>: <answer>", or, before #2574, "<label>
# finding <n>: <answer>", one per line) with the finding it answers.
# <out_assoc>[<key>] = the finding's text (its lines joined by a record
# separator), a unit separator, and the answer. The text is the one that
# travelled with the answer (_JUDGE_ANSWER_FINDING, judge_answers_to_v) when it
# did; else the finding with that id, or finding <n> of the result its <label>
# names. An answer whose finding is found nowhere keeps an empty text: it is
# never given another finding's (#2574). One jq for every result (#2569,
# ADR-072 §5); none when there is no answer.
judge_answered_findings_v() {
    local -n _jaf="$1"; local _jaf_ans="$2" _jaf_p _jaf_l _jaf_n _jaf_k _jaf_t _jaf_f _jaf_i
    shift 2
    _jaf=()
    local -A _jaf_file=() _jaf_label=() _jaf_txt=()
    for _jaf_p in "$@"; do
        [[ "$_jaf_p" == *=* ]] || continue
        _jaf_file["${_jaf_p%%=*}"]="${_jaf_p#*=}"
    done
    local -a _jaf_order=() _jaf_fs=()
    local -A _jaf_said=()
    local _jaf_re='^([A-Za-z0-9_-]+) finding ([0-9]+)[[:space:]]*:[[:space:]]*(.*)$'
    local _jaf_ire='^('"$_ZB_FID_RE"')[[:space:]]*:[[:space:]]*(.*)$'
    while IFS= read -r _jaf_l; do
        if [[ "$_jaf_l" =~ $_jaf_ire ]]; then
            _jaf_k="${BASH_REMATCH[1]}"; _jaf_t="${BASH_REMATCH[2]}"
        elif [[ "$_jaf_l" =~ $_jaf_re ]]; then
            _jaf_k="${BASH_REMATCH[1]} finding ${BASH_REMATCH[2]}"; _jaf_t="${BASH_REMATCH[3]}"
            [[ -n "${_jaf_file[${BASH_REMATCH[1]}]+x}" ]] || continue
        else
            continue
        fi
        [[ -n "${_jaf_said[$_jaf_k]+x}" ]] || _jaf_order+=("$_jaf_k")
        _jaf_said["$_jaf_k"]="$_jaf_t"
    done <<< "$_jaf_ans"
    [[ ${#_jaf_order[@]} -gt 0 ]] || return 0
    for _jaf_l in "${!_jaf_file[@]}"; do
        _jaf_f="${_jaf_file[$_jaf_l]}"
        [[ -s "$_jaf_f" ]] || continue
        [[ -n "${_jaf_label[$_jaf_f]+x}" ]] || _jaf_fs+=("$_jaf_f")
        _jaf_label["$_jaf_f"]+="$_jaf_l"$'\n'
    done
    if [[ ${#_jaf_fs[@]} -gt 0 ]]; then
        while IFS=$'\t' read -r _jaf_f _jaf_n _jaf_i _jaf_t; do
            [[ -n "$_jaf_f" ]] || continue
            # An old-form answer names only a finding that has no id (review on #2574).
            [[ "$_jaf_i" != - ]] && { _jaf_txt["$_jaf_i"]="$_jaf_t"; continue; }
            while IFS= read -r _jaf_l; do
                [[ -n "$_jaf_l" ]] && _jaf_txt["$_jaf_l finding $_jaf_n"]="$_jaf_t"
            done <<< "${_jaf_label[$_jaf_f]:-}"
        done < <(jq -r 'input_filename as $f | (.data.findings // [])[]? | select((.n | type) == "number")
            | "\($f)\t\(.n)\t\(if (.id | type) == "string" then .id else "-" end)\t\(.text | tostring | gsub("[\t]"; " ") | gsub("\r?\n"; "\u001e"))"' "${_jaf_fs[@]}" 2>/dev/null)
    fi
    for _jaf_k in "${_jaf_order[@]}"; do
        if [[ -n "${_JUDGE_ANSWER_FINDING[$_jaf_k]+x}" ]]; then _jaf_t="${_JUDGE_ANSWER_FINDING[$_jaf_k]//$'\n'/$'\x1e'}"
        else _jaf_t="${_jaf_txt[$_jaf_k]:-}"; fi
        _jaf["$_jaf_k"]="$_jaf_t"$'\x1f'"${_jaf_said[$_jaf_k]}"
    done
}

# What a check is shown of each earlier finding, at most (review on #2569):
# the finding's text and the answer are model text, so each is capped, and so
# is how many are shown.
_JUDGE_HELD_MAX_TEXT=1200 _JUDGE_HELD_MAX_ANSWER=500 _JUDGE_HELD_MAX_ENTRIES=20

# judge_held_entry_v <var> <key> <value> [same|changed] — one earlier finding
# and its answer, as a check is shown it: the key judge_answered_findings_v
# gives, the finding with each of its lines indented, and what was answered,
# each capped. [same]: the part, and every file read for it, are as they were
# when it was refused — a done answer changed nothing in it; [changed]: they
# are not (review on #2569). Nothing is said when it is not known.
judge_held_entry_v() {
    local -n _jhe="$1"; local _jhe_t="${3%%$'\x1f'*}" _jhe_a="${3#*$'\x1f'}"
    (( ${#_jhe_t} > _JUDGE_HELD_MAX_TEXT )) && _jhe_t="${_jhe_t:0:_JUDGE_HELD_MAX_TEXT}… (cut)"
    (( ${#_jhe_a} > _JUDGE_HELD_MAX_ANSWER )) && _jhe_a="${_jhe_a:0:_JUDGE_HELD_MAX_ANSWER}… (cut)"
    _jhe_t="${_jhe_t//$'\x1e'/$'\n'    }"; _jhe_a="${_jhe_a//$'\n'/ }"
    _jhe="- $2: ${_jhe_t:-(its text is not kept)}"$'\n'"  answered: $_jhe_a"$'\n'
    case "${4:-}" in
        same)    _jhe+="  this part: the same, word for word, as when you refused it — and so is every file you read for it"$'\n' ;;
        changed) _jhe+="  this part: it, or a file you read for it, has changed since you refused it"$'\n' ;;
    esac
}

# judge_held_entries_v <var> <answers> <label>=<result_json>... — every answer
# of <answers> with the finding it answers (judge_answered_findings_v), each
# rendered by judge_held_entry_v, in the order answered: for a check that
# judges one item, all of it is held (#2569).
judge_held_entries_v() {
    local -n _jhs_v="$1"; local _jhs_a="$2" _jhs_l _jhs_k _jhs_e
    shift 2
    _jhs_v=""
    [[ -n "$_jhs_a" ]] || return 0
    local -A _jhs_af=()
    judge_answered_findings_v _jhs_af "$_jhs_a" "$@"
    local _jhs_re='^('"$_ZB_FID_RE"'|[A-Za-z0-9_-]+ finding [0-9]+)[[:space:]]*:'
    while IFS= read -r _jhs_l; do
        [[ "$_jhs_l" =~ $_jhs_re ]] || continue
        _jhs_k="${BASH_REMATCH[1]}"
        [[ -n "${_jhs_af[$_jhs_k]+x}" ]] || continue
        judge_held_entry_v _jhs_e "$_jhs_k" "${_jhs_af[$_jhs_k]}"; unset '_jhs_af[$_jhs_k]'
        _jhs_v+="$_jhs_e"
    done <<< "$_jhs_a"
}

# judge_held_block_v <var> <entries> — what a check is shown of the parts it
# refused before and the answers to them (#2569, ADR-072 §5): it says whether
# each answer resolves its finding. At most _JUDGE_HELD_MAX_ENTRIES entries,
# and how many more there were. Empty when there is none; no process.
judge_held_block_v() {
    local -n _jhb="$1"; local _jhb_l _jhb_e="" _jhb_n=0 _jhb_more=0
    _jhb=""
    [[ -n "${2//[[:space:]]/}" ]] || return 0
    while IFS= read -r _jhb_l; do
        [[ "$_jhb_l" == "- "* ]] && _jhb_n=$(( _jhb_n + 1 ))
        if (( _jhb_n > _JUDGE_HELD_MAX_ENTRIES )); then [[ "$_jhb_l" == "- "* ]] && _jhb_more=$(( _jhb_more + 1 )); continue; fi
        _jhb_e+="$_jhb_l"$'\n'
    done <<< "$2"
    (( _jhb_more )) && _jhb_e+="($_jhb_more more earlier findings are not shown: judge those parts from scratch)"$'\n'
    _jhb=$'\n''YOUR EARLIER FINDINGS, AND THE ANSWERS TO THEM — each part below is one you refused before: your finding, with its ACCEPTED IF, and the answer of the stage that had to act on it — done (it changed what you found), wrong (your finding does not hold, and why) or not mine (another stage must act). Where it is known, each also says, under this part:, whether you are judging the same text as when you refused it: a done answer to a part whose text is the same changed nothing in it. For each, say whether the answer resolves it. When it does — your ACCEPTED IF now holds, or the answer shows your finding was wrong — answer that part as you answer a part with nothing wrong. When it does not, refuse it again in your refusal form, with a WHY that says why the answer does not resolve it. Judge every part not listed here from scratch.'$'\n'"$_jhb_e"
}

# judge_last_findings_block_v <var> <artifact_dir> <label> <result_json>... —
# what a stage that reports findings is shown of its own findings from last
# time: each one, with every answer a stage gave it (ADR-068 §6, ADR-072 §5).
# Its grade holds unless it can quote what changed: on #1805 run 42374066107 the
# same finding was low one round and medium the next. Pairs of <label> and its
# result; empty when there were none. No process when no result exists.
judge_last_findings_block_v() {
    local -n _jlf="$1"; shift
    local dir="${1%/}"; shift
    local _jlf_l _jlf_f _jlf_body="" _jlf_ans="" _jlf_s f
    local -a _jlf_with=()
    _jlf=""
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        _jlf_s=""; IFS= read -r -d '' _jlf_s < "$f" || true
        [[ "$_jlf_s" == *'"answers"'* ]] && _jlf_with+=("$f")
    done
    while [[ $# -ge 2 ]]; do
        _jlf_l="$1" _jlf_f="$2"; shift 2
        [[ -s "$_jlf_f" ]] || continue
        _jlf_s=""; IFS= read -r -d '' _jlf_s < "$_jlf_f" || true
        [[ "$_jlf_s" == *'"findings"'* ]] || continue
        _jlf_ans=""
        # #2574: an answer names the finding's id, or (before ids) its place.
        [[ ${#_jlf_with[@]} -gt 0 ]] && _jlf_ans="$(jq -r --arg re "^(${_jlf_l//[^A-Za-z0-9_-]/.} finding [0-9]+|$_ZB_FID_RE)[[:space:]]*:" \
            '(.data.answers // [])[]? | strings | select(test($re))' "${_jlf_with[@]}" 2>/dev/null)"
        _jlf_body+="$(jq -r --arg l "$_jlf_l" --arg a "$_jlf_ans" '
            ($a | split("\n") | map(select(length > 0))) as $ans
            | (.data.findings // [])[]? | select((.n | type) == "number")
            | "\($l) finding \(.n)" as $old
            | (if (.id | type) == "string" then .id else $old end) as $k
            | "- \($k): \(.text | tostring | split("\n")[0])"
              + ([$ans[] | . as $x | ([$k] | map(select(. as $y | $x | startswith($y + ":"))) | first) as $m
                  | select($m != null) | "\n  answered: " + ($x | ltrimstr($m + ":") | ltrimstr(" "))] | join(""))' "$_jlf_f" 2>/dev/null)"$'\n'
    done
    [[ -n "${_jlf_body//[[:space:]]/}" ]] || return 0
    _jlf=$'\n'"YOUR FINDINGS LAST TIME — each with what the stages given it answered. A finding you report again keeps the grade you gave it, unless you quote what changed since that makes it worse. For each one answered — done, wrong or not mine — say whether the answer resolves it: when it does (its ACCEPTED IF now holds, or the answer shows it was wrong), do not report it again; when it does not, report it again, its message saying why the answer does not resolve it."$'\n'"${_jlf_body%$'\n'}"
}

# A part handed to another stage waits for it (#2574): judge-handoff.sh.
# shellcheck source=judge-handoff.sh
source "${BASH_SOURCE[0]%/*}/judge-handoff.sh"
