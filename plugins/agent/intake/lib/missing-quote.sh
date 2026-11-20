#!/usr/bin/env bash
# plugins/agent/intake/lib/missing-quote.sh — a requirement the check says the
# list misses is in the issue's words (#2569, ADR-070 §1): whole sentences of
# the issue, copied as written, with the marks the judges' quote check sets
# aside (_judge_marks_v, ADR-072 §3) aside.
#
# On #1764 run 44530053809 the check wrote R6 as four paraphrased pieces and
# lost its main point. A part of a sentence is refused too: "the label calls …
# are in …" was a true run of R6's words that kept only its smallest part.
#
# Sourced library (by requirements.sh, which loads judge.sh): no set -euo pipefail.

[[ -n "${_ZBUILD_INTAKE_MISSING_QUOTE_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_MISSING_QUOTE_LOADED=1

# _ireq_units_v <var> <text> — <text> one unit a line: a paragraph's lines
# joined (a person hard-wraps a sentence), broken only at a blank line, a list
# mark, a heading, a table row or a code fence. A list item's continuation
# lines and its sub-bullets (marked further in) are part of the item. A line's
# bullet, checkbox or number and an item label of the issue's ("**R6.**") are
# dropped, so the item's sentence starts after them.
_ireq_units_v() {
    local -n _iuv="$1"; local _l _sp _o="" _u="" _item=-1 _fence=0
    local _mk='^([-*+]([[:space:]]+\[[ xX]\])?|[0-9]+[.)])[[:space:]]+'
    local _lab='^(\*\*|__)?[A-Z]{1,3}[0-9]{1,3}((\*\*|__)?[.:)]|[.:)](\*\*|__)?)[[:space:]]+'
    while IFS= read -r _l || [[ -n "$_l" ]]; do
        _l="${_l%$'\r'}"
        _sp="${_l%%[![:space:]]*}"; _l="${_l#"$_sp"}"; _l="${_l%"${_l##*[![:space:]]}"}"
        if [[ "$_l" == '```'* || "$_l" == '~~~'* ]]; then
            _o+="${_u:+$_u$'\n'}"; _u=""; _item=-1; _fence=$(( 1 - _fence )); continue
        fi
        if (( _fence )) || [[ -z "$_l" || "$_l" == '#'* || "$_l" == '|'* ]]; then
            _o+="${_u:+$_u$'\n'}"; _u=""; _item=-1
            while [[ "$_l" == '#'* ]]; do _l="${_l#\#}"; done
            [[ -n "$_l" ]] && _o+="$_l"$'\n'
            continue
        fi
        if [[ "$_l" =~ $_mk ]]; then
            _l="${_l:${#BASH_REMATCH[0]}}"
            [[ "$_l" =~ $_lab ]] && _l="${_l:${#BASH_REMATCH[0]}}"
            if (( _item >= 0 && ${#_sp} > _item )); then _u+=" $_l"
            else _o+="${_u:+$_u$'\n'}"; _u="$_l"; _item=${#_sp}; fi
            continue
        fi
        [[ -z "$_u" && "$_l" =~ $_lab ]] && _l="${_l:${#BASH_REMATCH[0]}}"
        _u+="${_u:+ }$_l"
    done <<< "$2"
    _iuv="$_o${_u:+$_u$'\n'}"
}

# _ireq_norm_v <var> <text> — <text> as the comparison reads it: its units
# (_ireq_units_v), each sentence followed by a \x1e mark — a unit ends one, and
# so does a stop and a space inside it; a stop or colon before a mark is
# dropped, so a quote may leave it off. The marks _judge_marks_v sets aside are
# dropped, and commas, semicolons and a lone `-` or `+` (a sub-bullet's mark
# written inline), so an item's sub-points may be joined either way; spacing is
# one space. An issue label (R6, R1–R5) and a list id (RQCLM-1) are each one
# \x1c, and ids joined by "and", "or", "to" or a dash are one: the check is
# told to write the list's ids where the issue writes its labels.
# Bytewise (LC_ALL=C): a multibyte locale makes bash's pattern matching slow
# on a long issue.
_ireq_norm_v() {
    local -n _inv="$1"; local LC_ALL=C _s _w _o="" _p _re _prev
    local _id="([A-Z]{1,3}[0-9]{1,3}|${_IREQ_PX:-RQ}[A-Z][A-Z0-9]{2,3}-[0-9]+)"
    _re="^([^[:alnum:]]*)${_id}((–|—|-|to)${_id})?([^[:alnum:]]*)$"
    _ireq_units_v _s "$2"
    _s="${_s//$'\n'/ $'\x1e' }"
    _judge_marks_v _s "$_s"
    _s="${_s//[,;]/}"
    local -a _ws=()
    read -r -d '' -a _ws <<< "$_s" || true
    for _w in "${_ws[@]+"${_ws[@]}"}"; do
        [[ "$_w" == - || "$_w" == + ]] && continue
        [[ "$_w" == *[0-9]* && "$_w" =~ $_re ]] && _w="${BASH_REMATCH[1]}"$'\x1c'"${BASH_REMATCH[6]}"
        _o+="$_w "
    done
    _prev=""
    while [[ "$_o" != "$_prev" ]]; do
        _prev="$_o"
        for _p in ' and ' ' or ' ' to ' ' through ' ' & ' ' – ' ' — ' ' '; do
            _o="${_o//$'\x1c'"$_p"$'\x1c'/$'\x1c'}"
        done
    done
    for _p in . '?' '!'; do _o="${_o//"$_p "/"$_p "$'\x1e' }"; done
    _o+=$'\x1e'
    for _p in . '?' '!' ':'; do _o="${_o//"$_p "$'\x1e'/ $'\x1e'}"; done
    while [[ "$_o" == *$'\x1e \x1e'* ]]; do _o="${_o//$'\x1e \x1e'/$'\x1e'}"; done
    _inv="$_o"
}

# _ireq_issue_norm_v <var> <issue> — the issue made ready for _ireq_in_norm:
# once a call, however many lines are held to it (#2569 review: a 195 KB issue
# took seconds a line, and issues over 1 MiB exist).
_ireq_issue_norm_v() {
    local -n _iin="$1"; local _n
    _ireq_norm_v _n "$2"
    _iin=$'\x1e '"$_n"
}

# _ireq_in_norm <text> <issue_norm> — rc 0 when <text> is whole sentences of
# the issue, in order: it starts where one of its sentences starts and ends
# where one ends. A model escapes characters it copies (\" \` \$, #2487): read
# as written first, then with each escape read as the character it stands for.
_ireq_in_norm() {
    local LC_ALL=C _q _u
    _ireq_norm_v _q "$1"
    [[ "$_q" == *[[:alnum:]]* ]] || return 1
    [[ "$2" == *$'\x1e '"$_q"* ]] && return 0
    [[ "$1" == *\\* ]] || return 1
    _u="${1//\\\\/$'\x01'}"; _u="${_u//\\/}"; _u="${_u//$'\x01'/\\}"
    _ireq_norm_v _q "$_u"
    [[ "$2" == *$'\x1e '"$_q"* ]]
}

# _ireq_in_issue <text> <issue> — _ireq_in_norm for one text.
_ireq_in_issue() {
    local _ni; _ireq_issue_norm_v _ni "$2"
    _ireq_in_norm "$1" "$_ni"
}
