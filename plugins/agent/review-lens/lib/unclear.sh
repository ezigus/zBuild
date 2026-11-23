#!/usr/bin/env bash
# plugins/agent/review-lens/lib/unclear.sh — what a lens finds unclear in the
# issue (#2571, ADR-038, ADR-069 §12).
#
# An issue whose words could mean either of two things is not wrong: the lens
# writes a question in the one form in its report's "unclear" list, judges the
# change by the reading it assumed, and the question is kept in its result
# (data.unclear) — and no run stop. A question it raises is never free: it
# reaches design as a finding that blocks nothing, as issue-acceptance's do. An
# issue that is wrong is still a `fix: issue` finding. Each question is held to
# the one form against the issue (zb_unclear_check_v) and a bad one is asked
# again with the lens's re-ask. The questions a lens carried from its last
# result are judged by its next call (zb_unclear_judge_block_v), its answers
# given in the report's "unclear_answers" list and read by the shared reader
# (zb_unclear_answers_v): answered or not needed is dropped — and recorded in
# data.unclear_dropped — open is kept, none is asked again. A question is never
# a finding's verdict: after the one re-ask, a line still not in its form is
# left out and one carried with no usable answer is kept, each with a note.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_LENS_UNCLEAR_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_UNCLEAR_LOADED=1
# shellcheck source=../../../../scripts/lib/unclear.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/unclear.sh"

# The rule every lens is told, with the place in its report: a string, so the
# prompt takes it with no subshell (ADR-065).
# shellcheck disable=SC2034  # read by the lens's prompt (charters.sh)
_RL_UNCLEAR_RULES="${ZB_UNCLEAR_RULES}
In this report each such question is a line of its own, not a finding:
  UNCLEAR <id> | \"<the issue's words>\" | <the readings> | ASSUMED: <the reading>
<id> is the id of the requirement it is about, as THE REQUIREMENTS list it.
An issue whose words could mean either of two things is not wrong: it is a question, never fix: issue.
Judge the change by the reading you assumed. An issue that is wrong — it
contradicts an ADR, or asks for something that cannot be built as written — is
still a finding with fix: issue."

# _rl_unclear_carried_load <result_json> — the questions the lens's last result
# carries (data.unclear), readable ones only: _RL_UQ_CARRIED (a line each, for
# its next call to judge) and _RL_UQ_JSON (what a result keeps until they are
# judged); _RL_UQ_ISSUE is cleared (the issue's words, read when first needed).
_rl_unclear_carried_load() {
    local -a _ruc=() _ruc_ok=(); local _ruc_l _ruc_p
    _RL_UQ_CARRIED=""; _RL_UQ_JSON="[]"; _RL_UQ_ISSUE=""; _RL_UQ_ISSUE_READ=""
    _RL_UQ_DROPPED="[]"; _RL_UQ_NOTES=""; _RL_UQ_NEWQ="[]"
    zb_unclear_result_lines_v _ruc "${1:-}"
    for _ruc_l in ${_ruc[@]+"${_ruc[@]}"}; do
        zb_unclear_parse_v _ruc_p "$_ruc_l" || continue
        _RL_UQ_CARRIED+="$_ruc_l"$'\n'; _ruc_ok+=("$_ruc_l")
    done
    zb_unclear_result_json_v _RL_UQ_JSON _ruc_ok
}

# _rl_unclear_block_v <var> — what the next call is shown about the questions
# it carried, or empty when it carries none.
_rl_unclear_block_v() {
    local -n _rub="$1"; local _rub_b=""
    _rub=""
    zb_unclear_judge_block_v _rub_b "${_RL_UQ_CARRIED:-}"
    [[ -n "$_rub_b" ]] || return 0
    _rub=$'\n\n'"$_rub_b"$'\n'"Answer each of these on a line of its own in your report, for example: UNCLEAR <id>: open"$'\n'
}

# _rl_unclear_plain_v <var> <line> — a question as the lens wrote it, with the
# formatting around it aside (a list bullet or number, bold or code marks).
_rl_unclear_plain_v() { zb_unclear_plain_v "$@"; }

# _rl_unclear_problem_v <var> <json> — what is wrong with the report's questions
# and its answers to the carried ones, or empty. Sets _RL_UQ_NEW (each good
# question it raised), _RL_UQ_BAD (each one not in the form), _RL_UQ_DROP (each
# carried one answered or not needed) and _RL_UQ_KEPT (the ids of those open).
# One jq, only for a report that holds a question or an answer.
_rl_unclear_problem_v() {
    local -n _rup="$1"; local _rup_t _rup_l _rup_w _rup_ans="" _rup_p=""; local -a _rup_bad=()
    _rup=""; _RL_UQ_NEW=(); _RL_UQ_DROP=(); _RL_UQ_KEPT=(); _RL_UQ_BAD=()
    [[ "$2" == *'"unclear'* || -n "${_RL_UQ_CARRIED:-}" ]] || return 0
    if [[ -z "${_RL_UQ_ISSUE_READ:-}" ]]; then
        _RL_UQ_ISSUE="$(earlier_issue_text "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
        _RL_UQ_ISSUE_READ=1
    fi
    if [[ "$2" == *'"unclear'* ]]; then
        while IFS=$'\t' read -r _rup_t _rup_l; do
            [[ -n "$_rup_l" ]] || continue
            _rl_unclear_plain_v _rup_l "$_rup_l"
            if [[ "$_rup_t" == A ]]; then _rup_ans+="$_rup_l"$'\n'; continue; fi
            if zb_unclear_check_v _rup_w "$_rup_l" "$_RL_UQ_ISSUE"; then _RL_UQ_NEW+=("$_rup_l")
            else _rup_bad+=("the unclear line \"${_rup_l:0:120}\" $_rup_w"); _RL_UQ_BAD+=("$_rup_l"); fi
        done < <(jq -r '((.unclear // []) | if type == "array" then .[] else empty end | strings | "Q\t" + gsub("[\r\n\t]+"; " ")),
                        ((.unclear_answers // []) | if type == "array" then .[] else empty end | strings | "A\t" + gsub("[\r\n\t]+"; " "))' <<< "$2" 2>/dev/null)
    fi
    if [[ -n "${_RL_UQ_CARRIED:-}" ]]; then
        zb_unclear_answers_v _RL_UQ_KEPT _RL_UQ_DROP _rup_p "$_rup_ans" "$_RL_UQ_CARRIED" "$_RL_UQ_ISSUE"
        [[ -n "$_rup_p" ]] && _rup_bad+=("in unclear_answers: $_rup_p")
    fi
    [[ ${#_rup_bad[@]} -gt 0 ]] || return 0
    judge_problems_join_v _rup _rup_bad
}

# _rl_unclear_settle <json> — from the lens's final report: _RL_UQ_JSON for its
# result, each carried question not dropped, then each good one raised now
# whose id was not carried; _RL_UQ_NEWQ, those raised now, as JSON, each a
# finding for design; _RL_UQ_DROPPED, each dropped one with its WHY, QUOTE and
# the question (JSON, for data.unclear_dropped: zb_unclear_dropped_json_v); _RL_UQ_NOTES, a line for
# each carried one with no usable answer, each line left out, and any over the
# most a stage carries. Only the lens's own call retires its question.
_rl_unclear_settle() {
    local _rus_p="" _rus_l _rus_x _rus_id _rus_n=""; local -A _rus_drop=() _rus_have=() _rus_open=(); local -a _rus_out=() _rus_new=()
    _RL_UQ_NOTES=""; _RL_UQ_NEWQ="[]"
    _rl_unclear_problem_v _rus_p "${1:-}"
    zb_unclear_dropped_json_v _RL_UQ_DROPPED _RL_UQ_DROP "${_RL_UQ_CARRIED:-}"
    for _rus_l in ${_RL_UQ_DROP[@]+"${_RL_UQ_DROP[@]}"}; do _rus_drop["${_rus_l%%$'\t'*}"]=1; done
    for _rus_l in ${_RL_UQ_KEPT[@]+"${_RL_UQ_KEPT[@]}"}; do _rus_open["$_rus_l"]=1; done
    while IFS= read -r _rus_l; do
        [[ -n "$_rus_l" ]] && zb_unclear_parse_v _rus_x "$_rus_l" || continue
        _rus_id="${_rus_x%%$'\t'*}"
        [[ -n "${_rus_have[$_rus_id]+x}" ]] && continue
        _rus_have["$_rus_id"]=1
        [[ -n "${_rus_drop[$_rus_id]+x}" ]] && continue
        [[ -n "${_rus_open[$_rus_id]+x}" ]] || _RL_UQ_NOTES+="UNCLEAR $_rus_id: no usable answer after it was asked again — kept open"$'\n'
        _rus_out+=("$_rus_l")
    done <<< "${_RL_UQ_CARRIED:-}"
    for _rus_l in ${_RL_UQ_NEW[@]+"${_RL_UQ_NEW[@]}"}; do
        zb_unclear_parse_v _rus_x "$_rus_l" || continue
        _rus_id="${_rus_x%%$'\t'*}"
        [[ -n "${_rus_have[$_rus_id]+x}" ]] && continue
        _rus_have["$_rus_id"]=1; _rus_out+=("$_rus_l"); _rus_new+=("$_rus_l")
    done
    for _rus_l in ${_RL_UQ_BAD[@]+"${_RL_UQ_BAD[@]}"}; do
        _RL_UQ_NOTES+="an UNCLEAR line was left out, still not in its form after it was asked again: ${_rus_l:0:200}"$'\n'
    done
    zb_unclear_result_json_v _RL_UQ_JSON _rus_out _rus_n
    [[ -n "$_rus_n" ]] && _RL_UQ_NOTES+="$_rus_n"$'\n'
    zb_unclear_result_json_v _RL_UQ_NEWQ _rus_new
}

# _rl_unclear_data_v <var> <normalized> — <normalized> with the questions the
# lens goes on with (data.unclear), those it retired (data.unclear_dropped) and
# its notes (data.notes). One jq, only when there is any.
_rl_unclear_data_v() {
    local -n _rud="$1"
    _rud="$2"
    [[ "${_RL_UQ_JSON:-[]}" != "[]" || "${_RL_UQ_DROPPED:-[]}" != "[]" || -n "${_RL_UQ_NOTES:-}" ]] || return 0
    _rud="$(jq -c --argjson u "${_RL_UQ_JSON:-[]}" --argjson ud "${_RL_UQ_DROPPED:-[]}" --arg un "${_RL_UQ_NOTES:-}" '
        .data = ((.data // {})
          + (if ($u | length) > 0 then {unclear: $u} else {} end)
          + (if ($ud | length) > 0 then {unclear_dropped: $ud} else {} end)
          + ($un | split("\n") | map(select(length > 0)) | if length > 0 then {notes: .} else {} end))' <<< "$2" 2>/dev/null)" || _rud="$2"
    [[ -n "$_rud" ]] || _rud="$2"
}
