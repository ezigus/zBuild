#!/usr/bin/env bash
# plugins/agent/intake/lib/unclear.sh — what intake finds unclear in the issue
# (#2571, ADR-070 §1, ADR-069 §12): raised by its writing call in the one form,
# kept in intake's result (data.unclear), and judged each try by its check.
#
# The writing call is told the rule (ZB_UNCLEAR_RULES) and each line it writes
# is held to the one form against the issue (zb_unclear_check_v); a bad line is
# asked again with intake's re-ask, and left out — noted — if it is still bad.
# The check (the missing-requirements call) is shown the questions intake
# carried from its last result (zb_unclear_judge_block_v) and its answers are
# read by the shared reader (zb_unclear_answers_v): answered or not needed is
# dropped, open is kept, and a question it gives no usable answer for is asked
# again, then kept: only intake's own check retires intake's question.
#
# Sourced library (by requirements.sh): no set -euo pipefail.

[[ -n "${_ZBUILD_INTAKE_UNCLEAR_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_UNCLEAR_LOADED=1
# shellcheck source=../../../../scripts/lib/unclear.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/unclear.sh"

# _ireq_unclear_carried_load <result_json> — the questions intake's last result
# carries (data.unclear), readable ones only, into _IREQ_UQ_CARRIED (one line
# each) and _IREQ_UQ_CARRIED_JSON (for a result written before they are judged).
_ireq_unclear_carried_load() {
    local -a _iuc=(); local _iuc_l _iuc_p
    _IREQ_UQ_CARRIED=""; _IREQ_UQ_CARRIED_JSON="[]"
    local -a _iuc_ok=()
    zb_unclear_result_lines_v _iuc "${1:-}"
    for _iuc_l in ${_iuc[@]+"${_iuc[@]}"}; do
        zb_unclear_parse_v _iuc_p "$_iuc_l" || continue
        _IREQ_UQ_CARRIED+="$_iuc_l"$'\n'; _iuc_ok+=("$_iuc_l")
    done
    zb_unclear_result_json_v _IREQ_UQ_CARRIED_JSON _iuc_ok
}

# _ireq_unclear_reply <label> <reply> <issue> <problem_var> — the UNCLEAR lines
# of one answer. For the writing call (REQUIREMENT) each line it raised: the good
# ones into _IREQ_UQ_NEW, what is wrong with the rest into <problem_var>
# (_IREQ_UQ_BAD keeps the bad lines, for the note). For the check (MISSING) its
# answers to the carried questions: _IREQ_UQ_DROP (as zb_unclear_answers_v gives
# them) and <problem_var>.
_ireq_unclear_reply() {
    local -n _iur_p="$4"; local _iur_l _iur_w; local -a _iur_all=() _iur_k=()
    _iur_p=""
    if [[ "$1" == MISSING ]]; then
        _IREQ_UQ_DROP=()
        [[ -n "${_IREQ_UQ_CARRIED:-}" ]] || return 0
        zb_unclear_answers_v _iur_k _IREQ_UQ_DROP _iur_p "$2" "$_IREQ_UQ_CARRIED" "$3"
        return 0
    fi
    _IREQ_UQ_NEW=(); _IREQ_UQ_BAD=()
    zb_unclear_lines_text_v _iur_all "$2"
    for _iur_l in ${_iur_all[@]+"${_iur_all[@]}"}; do
        if zb_unclear_check_v _iur_w "$_iur_l" "$3"; then _IREQ_UQ_NEW+=("$_iur_l"); continue; fi
        _IREQ_UQ_BAD+=("$_iur_l")
        _iur_p+="${_iur_p:+; }the line \"${_iur_l:0:120}\" $_iur_w"
    done
    return 0
}

# _ireq_unclear_result_v <var> — the questions for intake's result, as JSON:
# each carried one the check did not drop, then each new one whose id is not
# carried. Sets _INTAKE_UQ_DROPPED: each dropped question with its WHY, QUOTE and
# the question (JSON, for data.unclear_dropped, as every stage records one:
# zb_unclear_dropped_json_v), and _INTAKE_UQ_NOTES: a line for each line left
# out because it was still not in its form after the re-ask, and any over the
# most a stage carries.
_ireq_unclear_result_v() {
    local -n _iurv="$1"; local -A _iurv_drop=() _iurv_have=(); local -a _iurv_out=()
    local _iurv_l _iurv_p _iurv_id _iurv_n=""
    _INTAKE_UQ_NOTES=""
    zb_unclear_dropped_json_v _INTAKE_UQ_DROPPED _IREQ_UQ_DROP "${_IREQ_UQ_CARRIED:-}"
    for _iurv_l in ${_IREQ_UQ_DROP[@]+"${_IREQ_UQ_DROP[@]}"}; do _iurv_drop["${_iurv_l%%$'\t'*}"]=1; done
    while IFS= read -r _iurv_l; do
        [[ -n "$_iurv_l" ]] && zb_unclear_parse_v _iurv_p "$_iurv_l" || continue
        _iurv_id="${_iurv_p%%$'\t'*}"
        [[ -n "${_iurv_drop[$_iurv_id]+x}" || -n "${_iurv_have[$_iurv_id]+x}" ]] && continue
        _iurv_have["$_iurv_id"]=1; _iurv_out+=("$_iurv_l")
    done <<< "${_IREQ_UQ_CARRIED:-}"
    for _iurv_l in ${_IREQ_UQ_NEW[@]+"${_IREQ_UQ_NEW[@]}"}; do
        zb_unclear_parse_v _iurv_p "$_iurv_l" || continue
        _iurv_id="${_iurv_p%%$'\t'*}"
        [[ -n "${_iurv_have[$_iurv_id]+x}" ]] && continue
        _iurv_have["$_iurv_id"]=1; _iurv_out+=("$_iurv_l")
    done
    for _iurv_l in ${_IREQ_UQ_BAD[@]+"${_IREQ_UQ_BAD[@]}"}; do
        _INTAKE_UQ_NOTES+="an UNCLEAR line was left out, still not in its form after it was asked again: ${_iurv_l:0:200}"$'\n'
    done
    zb_unclear_result_json_v _iurv _iurv_out _iurv_n
    [[ -n "$_iurv_n" ]] && _INTAKE_UQ_NOTES+="$_iurv_n"$'\n'
    return 0
}
