#!/usr/bin/env bash
# plugins/agent/review-lens/lib/unchecked.sh — a lens finding that cannot be
# checked costs only itself (#2598, ADR-072 §3, ADR-038). Split from plugin.sh
# (under 500 lines); each function reads and sets its caller's locals
# (dynamic scope): json, raw_response, _rl_try, _rl_problem, _rl_first,
# _rl_bad_idx, normalized, lens, _rl_change, _rl_repo.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

# shellcheck disable=SC2154  # the caller's locals, read and set by dynamic scope
[[ -n "${_ZBUILD_REVIEW_LENS_UNCHECKED_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_UNCHECKED_LOADED=1

# _rl_reask_merge — on the second try, the re-ask's findings take the places of
# the ones it was asked about in the first answer.
_rl_reask_merge() {
    # #2598: the re-ask was about some findings only — its answer takes
    # their places in the first answer; one that resends the whole answer
    # (as many findings) is taken whole.
    if [[ $_rl_try -eq 2 && -n "$_rl_first" ]]; then
        # The re-ask asks for FINDING blocks, so an answer of only those (no
        # SCORE line) is read as findings (review on #2598).
        [[ -n "$json" ]] || { _rl_reply_lines_v json "SCORE: 0"$'\n'"$raw_response"; [[ "$json" == *'"findings":[{'* && "$json" != *'"stray":true'* ]] || json=""; }
        [[ -n "$json" ]] || json="$_rl_first"
        _rl_problem=""
        [[ "$(jq '(.findings | length) < ($f.findings | length)' --argjson f "$_rl_first" <<< "$json" 2>/dev/null)" == true ]] \
            && json="$(jq -c --argjson f "$_rl_first" --argjson b "[$_rl_bad_idx]" '. as $n | $f
                | .findings |= (reduce range(0; $b | length) as $j (.; if $n.findings[$j] then .[$b[$j]] = $n.findings[$j] else . end))' <<< "$json" 2>/dev/null || printf '%s' "$_rl_first")"
    fi
}

# _rl_unchecked_settle — the first try asks again only for the findings that
# cannot be checked; the second keeps the rest and marks those unchecked.
_rl_unchecked_settle() {
    local _rl_bi _rl_bn=""
    # #2598 (ADR-072 §3): a finding that cannot be checked costs only itself.
    # Asked about again on its own; still not usable, the others are kept,
    # it is marked unchecked with why, and the lens fails on it.
    if [[ -n "$_rl_problem" && -n "$json" && ${#_RL_BAD_AT[@]} -gt 0 ]]; then
        if [[ $_rl_try -eq 1 ]]; then
            _rl_first="$json"; _rl_bad_idx=""
            for _rl_bi in $(printf '%s\n' "${!_RL_BAD_AT[@]}" | sort -n); do  # sigpipe-ok: sort reads all
                _rl_bad_idx+="${_rl_bad_idx:+,}$_rl_bi"; _rl_bn+="${_rl_bn:+, }$(( _rl_bi + 1 ))"
            done
            _rl_problem+=". Answer again only for finding ${_rl_bn}: write each as a FINDING block with all its fields, corrected, in that order; the other findings are kept as they are"
        else
            json="$(for _rl_bi in "${!_RL_BAD_AT[@]}"; do printf '%s\t%s\n' "$_rl_bi" "${_RL_BAD_AT[$_rl_bi]//$'\t'/ }"; done \
                | jq -Rn --argjson r "$json" '[inputs | split("\t") | {(.[0]): .[1]}] | add as $w
                    | $r | .findings |= [to_entries[] | .value + (if $w[.key | tostring] then {unchecked: $w[.key | tostring]} else {} end)]' 2>/dev/null)"
            [[ -n "$json" ]] && _rl_problem=""
        fi
    fi
}

# _rl_check_but_unchecked — the knock-down check, shown every finding but the
# unchecked ones, which keep their places in the result.
_rl_check_but_unchecked() {
    # #2598 (review): an unchecked finding is not shown to the knock-down
    # check — what could not be checked cannot be knocked down — and is put
    # back after it.
    local _rl_unck="[]"
    if [[ "$normalized" == *'"unchecked":'* ]]; then
        normalized="$(jq -c '.findings |= [to_entries[] | .value + {_at: .key}]' <<< "$normalized" 2>/dev/null || printf '%s' "$normalized")"
        _rl_unck="$(jq -c '[.findings[] | select((.unchecked // "") != "")]' <<< "$normalized" 2>/dev/null || printf '[]')"
        normalized="$(jq -c '.findings |= [.[] | select((.unchecked // "") == "")]' <<< "$normalized" 2>/dev/null || printf '%s' "$normalized")"
    fi
    _rl_check_v normalized "$normalized" "$lens" "$_rl_change" "$_rl_repo"
    [[ "$_rl_unck" != "[]" ]] && normalized="$(jq -c --argjson u "$_rl_unck" '.findings = ([.findings[], $u[]] | sort_by(._at // 0) | map(del(._at)))' <<< "$normalized" 2>/dev/null || printf '%s' "$normalized")"
}
