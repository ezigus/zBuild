#!/usr/bin/env bash
# plugins/agent/build/lib/steps-quote.sh — how build's step answers, and its judge's, are read
# (#2582; ADR-068 §6, ADR-072 §3 §4, amended 2026-11-21): a done's quote needs
# no label and may be part of one added line; an answer the check accepted
# stands on a later try that does not answer the step again.
#
# These run inside _build_steps_check (steps.sh) and read and set its locals —
# kind, said, qpath, qtxt, qune, added, reused — as _build_steps_said_v does.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_BUILD_STEPS_QUOTE_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_STEPS_QUOTE_LOADED=1

# _build_steps_quote_of_v <var> <raw line> — the quote of `step N: done —
# <file> | <line>`, written with no QUOTE: label, read from the line as the
# model wrote it: the reply reader drops backticks and bars, which a quoted
# line keeps.
_build_steps_quote_of_v() {
    local -n _bsqo="$1"; _bsqo=""
    local re='[Dd][Oo][Nn][Ee](.*)$'
    [[ "$2" =~ $re ]] || return 0
    _bsqo="${BASH_REMATCH[1]}"
    while :; do
        _build_steps_strip_v _bsqo "$_bsqo"
        [[ "$_bsqo" == \** ]] || break
        _bsqo="${_bsqo#\*}"
    done
}

# _build_steps_noanswer_v <var> <n> — the finding for a step with no answer.
_build_steps_noanswer_v() {
    local -n _bsna="$1"
    _bsna="step ${_BSL[$2]:-$2} has no answer: do it and answer \`step ${_BSL[$2]:-$2}: done\` with a \`quote: <file> | <a line this change added>\` line under it, or answer \`step ${_BSL[$2]:-$2}: not needed — <why>\` (the step: ${_BUILD_STEP_DESC[$2-1]})"
}

# _build_steps_stale_v <var> <n> <why> — the finding for a step whose answer,
# accepted on an earlier try, no longer stands, and why (review on #2582).
_build_steps_stale_v() {
    local -n _bsst="$1"
    _bsst="step ${_BSL[$2]:-$2}'s earlier answer no longer stands: $3 — answer it again (the step: ${_BUILD_STEP_DESC[$2-1]})"
}

# _build_steps_elide_v <var> <text> — <text> without an elision mark (... or
# …) at either end, nor the spaces beside it: such a mark is not in the line.
_build_steps_elide_v() {
    local -n _bse="$1"; _bse="$2"
    _bse="${_bse%…}"; _bse="${_bse%...}"; _bse="${_bse%"${_bse##*[![:space:]]}"}"
    _bse="${_bse#…}"; _bse="${_bse#...}"; _bse="${_bse#"${_bse%%[![:space:]]*}"}"
}

# _build_steps_quote_find <n> <repo> — rc 0 when step <n>'s quote is a line
# this branch added in its file, or part of exactly one (then qtxt[n] becomes
# that whole line, which is what is judged). Otherwise rc 1 and _BSQ_WHY says
# what is wrong, to follow "step <n>'s quote ".
_BSQ_WHY=""
_build_steps_quote_find() {
    local n="$1" repo="$2" f="${qpath[$1]}" t a hits cand l
    local lines="${added[${qpath[$1]}]:-}"
    local -a arr=()
    _BSQ_WHY=""
    for t in "${qtxt[$n]}" "${qune[$n]:-}"; do
        [[ -n "$t" && $'\x1e'"$lines" == *$'\x1e'"$t"$'\x1e'* ]] && { qtxt[$n]="$t"; return 0; }
    done
    IFS=$'\x1e' read -r -d '' -a arr <<< "$lines" || true
    # Each form, as written and with its escapes read, before any is refused.
    local many=""
    for t in "${qtxt[$n]}" "${qune[$n]:-}"; do
        _build_steps_elide_v t "$t"
        [[ -n "$t" ]] || continue
        hits=0; cand=""
        # #2609 (ADR-072 §3): the shared comparison (marks, quote marks, spacing,
        # escapes and `…` aside); build's own rule is only that the line is added.
        for a in ${arr[@]+"${arr[@]}"}; do _judge_holds "$a" "$t" && { hits=$((hits + 1)); cand="$a"; }; done
        if (( hits == 1 )); then qtxt[$n]="$cand"; return 0; fi
        (( hits > 1 )) && [[ -z "$many" ]] && many="$t"
    done
    if [[ -n "$many" ]]; then
        _BSQ_WHY="is part of more than one line this change added in $f: $many — quote one whole line you added that does the step"
        return 1
    fi
    # In no added line: say whether it is a line, or part of one, that was there.
    _build_steps_elide_v t "${qtxt[$n]}"
    hits=0; cand=""
    if [[ -n "$t" && -f "$repo/$f" ]]; then
        while IFS= read -r l || [[ -n "$l" ]]; do
            _build_steps_line_v l "$l"
            if [[ "$l" == "$t" ]]; then hits=-1; cand="$l"; break; fi
            [[ "$l" == *"$t"* ]] && { hits=$((hits + 1)); cand="$l"; }
        done < "$repo/$f"
    fi
    if (( hits == -1 )); then
        _BSQ_WHY="is a line this change did not add in $f: $cand — quote the line you added that does the step, or answer not needed and why"
    elif (( hits == 1 )); then
        _BSQ_WHY="is part of a line this change did not add in $f: $cand — quote the line you added that does the step, or answer not needed and why"
    else
        _BSQ_WHY="is not in any line of $f: ${qtxt[$n]} — quote the line you added that does the step, or answer not needed and why"
    fi
    return 1
}

# _build_steps_kept_answers <kept_file> <count> — a step this reply does not
# answer, and that is not waiting on another stage, takes the answer the check
# accepted for it on an earlier try (kept with its verdict); reused[n] marks it.
# It stands while its kept verdict does; when only the code it points to
# changed it is judged again on that answer; when its line is gone, or the step
# or a SPEC it serves changed, it no longer stands, and the finding says why
# (_build_steps_judge). One read of the kept file, only when a step is unanswered.
# shellcheck disable=SC2034  # its caller's arrays, read by _build_steps_check
_build_steps_kept_answers() {
    local kf="$1" count="$2" n x k
    for (( n = 1; n <= count; n++ )); do [[ -z "${kind[$n]:-}" && -z "${wait[$n]:-}" ]] && break; done
    (( n <= count )) && [[ -s "$kf" ]] || return 0
    local -A _bka_none=() _bka_out=()
    judge_kept_get_all_v _bka_out "$kf" _bka_none
    for (( n = 1; n <= count; n++ )); do
        [[ -z "${kind[$n]:-}" && -z "${wait[$n]:-}" ]] || continue
        x="${_JUDGE_KEPT_ANSWER[step-${_BSL[$n]:-$n}]:-}"
        [[ "$x" == *$'\n'* ]] || continue
        k="${x%%$'\n'*}"; x="${x#*$'\n'}"
        case "$k" in
            done) [[ "$x" == *$'\n'* ]] || continue
                  qpath[$n]="${x%%$'\n'*}"; qtxt[$n]="${x#*$'\n'}"; qune[$n]=""; said[$n]="" ;;
            not)  said[$n]="$x"; qpath[$n]=""; qtxt[$n]=""; qune[$n]="" ;;
            *)    continue ;;
        esac
        kind[$n]="$k"; reused[$n]=1
    done
}

# _build_steps_answer_record_v <var> <n> — step <n>'s answer as it is kept
# with an accepted verdict: its kind, then its file and line, or its reason.
_build_steps_answer_record_v() {
    local -n _bsar="$1"
    if [[ "${kind[$2]}" == "done" ]]; then _bsar="done"$'\n'"${qpath[$2]}"$'\n'"${qtxt[$2]}"
    else _bsar="not"$'\n'"${said[$2]}"; fi
}

# _build_steps_parse <reply> <wanted…> — each answer into _BSJ_ANS (n → "does"
# or "does not<US>why<US>accepted if"); _BSJ_PROBLEM says what makes the reply
# unusable. A step's good line is in _BSJ_ANS even when another's is not. A
# does not with no ACCEPTED IF is judged against the step: its ACCEPTED IF is
# the step's own words (ADR-072 §3; review on #2569).
_build_steps_parse() {
    local raw="$1" l n why acc; shift
    local -A want=(); for n in "$@"; do want[$n]=1; done
    declare -gA _BSJ_ANS=(); _BSJ_PROBLEM=""
    local -a bad=() units=()
    local start='^[[:space:]>*_`-]*[0-9]+[[:space:]]*[:.)]'
    # #2609 (ADR-072 §3): a block answer is one line first (the shared reader);
    # from here `raw` holds that joined form.
    _zb_reply_blocks_v raw "$raw"
    # A line the model wrapped is read whole: each answer starts `<n>:`.
    while IFS= read -r l; do
        if [[ "$l" =~ $start || ${#units[@]} -eq 0 ]]; then units+=("$l")
        elif [[ -n "${l//[[:space:]]/}" ]]; then units[-1]+=" ${l#"${l%%[![:space:]]*}"}"; fi
    done <<< "$raw"
    for l in ${units[@]+"${units[@]}"}; do
        judge_reply_line_v l "$l"
        [[ "${l,,}" =~ ^([0-9]+(\.[0-9]+)?):[[:space:]]*(does[[:space:]]+not|does)([^a-z]|$) ]] || continue
        local -a _bsm=("${BASH_REMATCH[@]}")
        _build_steps_index_v n "${_bsm[1]}" || n=""
        [[ -n "$n" && -n "${want[$n]:-}" ]] || { bad+=("line ${_bsm[1]} names no step you were asked about"); continue; }
        if [[ "${_bsm[3]}" == does ]]; then _BSJ_ANS[$n]=does; continue; fi
        judge_reply_field_v why "$l" WHY; _build_steps_strip_v why "$why"
        # #2569 (ADR-072 §3): a refusal says what would be accepted — the step.
        judge_reply_field_v acc "$l" "ACCEPTED IF"
        [[ -n "$acc" ]] || acc="${_BUILD_STEP_DESC[n-1]:-the step}"
        _BSJ_ANS[$n]="does not"$'\x1f'"${why:-it does not do what the step says}"$'\x1f'"$acc"
    done
    for n in "$@"; do [[ -n "${_BSJ_ANS[$n]+x}" ]] || bad+=("step ${_BSL[$n]:-$n} has no line"); done
    if [[ ${#bad[@]} -gt 0 ]]; then judge_problems_join_v _BSJ_PROBLEM bad; fi
    return 0
}
