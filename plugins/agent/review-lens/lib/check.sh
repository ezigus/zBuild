#!/usr/bin/env bash
# plugins/agent/review-lens/lib/check.sh — a lens's findings, checked by a
# second call that tries to knock each one down (#2552, ADR-038, ADR-072 §3).
#
# The lens judges its own findings no further than its quote: on #1700 run
# 43663836927, 10 of 15 quoted a real line but described a case that cannot
# happen. This call is shown only the findings — file, severity, message,
# trigger, quote — never the lens's reasoning, and runs as the persona the
# manifest names for `check`, not as the lens's. A finding stands unless it is
# knocked down with a quote of the code that shows it cannot happen.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_LENS_CHECK_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_CHECK_LOADED=1

# _rl_check_prompt <findings> <change> — the check's own three parts.
_rl_check_prompt() {
    cat <<EOF
## What you own
Your job: for each finding below, try to show that it cannot happen. Read the
code each finding names, what calls it, and what feeds it its input. A finding
stands unless you can quote code that shows it cannot happen on a real run —
its trigger never occurs, or something already stops it. Judge only these
findings: add none of your own.

Answer one line for each finding, by its number:

<n>: stands
<n>: knocked down | WHY: <why it cannot happen> | QUOTE: <file> | <one line of the code that shows it>

Copy each QUOTE as it is, with no quote marks around it: it is checked, and a
knock-down whose quote is not there leaves the finding standing.

## What you judge against
THE CHANGE — the commit the branch started from and the files it changed; read
any change with git, as it says:
$2

THE FINDINGS:
$1

## What you must not do
- Do not add findings, and do not change any file.
- Do not knock a finding down for how it is worded: judge whether it can happen.
EOF
}

# _rl_check_parse <reply> <count> <repo> — each answer line into _RL_KNOCKED
# (n → "why<US>quote"); _RL_CHECK_PROBLEM says what makes the reply unusable: a
# finding with no line, or a line naming none. A knock-down whose quote is not
# in the code is no knock-down: the finding stands.
_rl_check_parse() {
    local raw="$1" count="$2" repo="$3" l n rest why quote w
    declare -gA _RL_KNOCKED=(); _RL_CHECK_PROBLEM=""
    local -A seen=()
    local -a bad=()
    while IFS= read -r l; do
        judge_reply_line_v l "$l"
        [[ "$l" =~ ^([0-9]+):[[:space:]]*(stands|knocked[[:space:]]+down)(.*)$ ]] || continue
        n="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[3]}"
        if (( n < 1 || n > count )); then bad+=("line $n names no finding"); continue; fi
        seen[$n]=1
        [[ "${BASH_REMATCH[2]}" == stands ]] && continue
        why=""; quote=""
        if [[ "$rest" == *"| WHY:"* ]]; then why="${rest#*| WHY:}"; why="${why%%| QUOTE:*}"; fi
        why="${why#"${why%%[![:space:]]*}"}"; why="${why%"${why##*[![:space:]]}"}"
        [[ "$rest" == *"| QUOTE:"* ]] && { quote="${rest#*| QUOTE:}"; quote="${quote#"${quote%%[![:space:]]*}"}"; }
        [[ -n "$quote" ]] && judge_quote_check_v w "$quote" "" "$repo" || continue
        _RL_KNOCKED[$n]="${why:-it cannot happen}"$'\x1f'"$quote"
    done <<< "$raw"
    for (( n = 1; n <= count; n++ )); do [[ -n "${seen[$n]+x}" ]] || bad+=("finding $n has no line"); done
    if [[ ${#bad[@]} -gt 0 ]]; then local IFS=';'; _RL_CHECK_PROBLEM="${bad[*]}"; _RL_CHECK_PROBLEM="${_RL_CHECK_PROBLEM//;/; }"; fi
    return 0
}

# _rl_check_v <var> <normalized> <lens> <out> <change> <change_fp> <repo> —
# <normalized> with each finding the check knocked down moved to knocked_down
# ({…finding, why, by_quote}), into <var>. No findings: no call. A reply that
# cannot be used, asked again once, leaves every finding standing.
_rl_check_v() {
    local -n _rlc="$1"; local norm="$2" lens="$3" out="$4" change="$5" cfp="$6" repo="$7"
    _rlc="$norm"
    local count list
    count="$(jq '.findings | length' <<< "$norm" 2>/dev/null || echo 0)"
    [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )) || return 0
    list="$(jq -r '.findings | to_entries[] | "### \(.key + 1)\nfile: \(.value.file)\nseverity: \(.value.severity)\nmessage: \(.value.message)\ntrigger: \(.value.trigger // "")\nquote: \(.value.quote)\n"' <<< "$norm" 2>/dev/null)"
    # ADR-072 §4: kept while the findings and the change are unchanged.
    local kf="${out%.json}-check-judged.json" eng fp kept="" reply="" ask prompt _try
    judge_engine_v eng
    judge_fp_v fp "$eng"$'\n'"$list"$'\n'"$cfp"
    judge_kept_get_v kept "$kf" check "$fp"
    if [[ -n "$kept" ]]; then
        _rl_check_parse "$kept" "$count" "$repo"
        [[ -z "$_RL_CHECK_PROBLEM" ]] && reply="$kept"
    fi
    if [[ -z "$reply" ]]; then
        prompt="$(stage_prompt_compose_parts --fresh "$(_rl_check_prompt "$list" "$change")")" || return 0
        ask="$prompt"
        for _try in 1 2; do
            local _r="" _rc=0
            # ADR-051 §5: the call the manifest names `check`, as its persona.
            _r="$(ZBUILD_ROUTE_CALL=check route_to_model "${_RL_CHECK_TIER:-T2}" "$ask")" || _rc=$?
            [[ "$_rc" -eq 0 && -n "$_r" ]] || break
            _rl_check_parse "$_r" "$count" "$repo"
            if [[ -z "$_RL_CHECK_PROBLEM" ]]; then
                reply="$_r"
                judge_kept_put_one "$kf" check "$fp" "$_r"
                break
            fi
            ask="$(stage_prompt_reask "$prompt" "$_RL_CHECK_PROBLEM" "$_r")"
        done
    fi
    if [[ -z "$reply" ]]; then
        emit_event "review_lens.check_unusable" "lens=$lens"
        return 0
    fi
    local kn="" n
    for n in "${!_RL_KNOCKED[@]}"; do kn+="$n"$'\x1f'"${_RL_KNOCKED[$n]}"$'\n'; done
    [[ -n "$kn" ]] || return 0
    _rlc="$(jq -c --arg k "$kn" '
        ($k | split("\n") | map(select(length > 0) | split("\u001f")) | map({key: .[0], value: {why: .[1], by_quote: .[2]}}) | from_entries) as $kd
        | .knocked_down = [.findings | to_entries[] | select($kd[(.key + 1 | tostring)]) | .value + $kd[(.key + 1 | tostring)]]
        | .findings = [.findings | to_entries[] | select($kd[(.key + 1 | tostring)] | not) | .value]' <<< "$norm" 2>/dev/null || printf '%s' "$norm")"
    emit_event "review_lens.checked" "lens=$lens" "knocked_down=$(jq '.knocked_down | length' <<< "$_rlc" 2>/dev/null || echo 0)"
    return 0
}
