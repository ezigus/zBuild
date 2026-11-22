#!/usr/bin/env bash
# plugins/agent/review-lens/lib/context.sh — what the change was for, as a lens
# is shown it: the issue, the requirements, the design's decisions (#2269, #1654).
# Split from plugin.sh (#2571: under 500 lines); its callers are there.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_LENS_CONTEXT_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_CONTEXT_LOADED=1

# _rl_context — what the change was for: the issue, its SPECs, the design's
# decisions, each whole and sanitised like the evidence (_rl_context_section_v).
# Every piece is optional; an absent one is simply left out.
# _rl_requirements_readable <design.md> — the acceptance block as a reviewer
# reads it (#2269): each requirement with what its status means (#2304,
# ADR-069), the evidence a done one names, the file that calls the new code,
# and the test files that check each one.
_rl_requirements_readable() {
    local design="$1" sid txt st kind tfs ev w blk _p
    # #2467: the block read once; each SPEC's words, status and parts from it.
    blk="$(extract_acceptance_block "$design" 2>/dev/null)" || blk=""
    # #2508: each SPEC's test files, found by tag, once.
    local -A _rl_files=()
    acceptance_spec_files_v _rl_files "$design"
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        txt="" st=""
        _acceptance_spec_line "$blk" "$sid" && { txt="$_ACC_SPEC_TEXT"; st="$_ACC_SPEC_STATUS"; }
        case "$st" in
            no-code) kind="work that changes no behaviour" ;;
            doc)     kind="a doc change — no test checks it" ;;
            done)    kind="already done — the code already does this" ;;
            *)       kind="new behaviour" ;;
        esac
        tfs="${_rl_files[$sid]:-}"
        printf -- '- %s (%s): %s\n' "$sid" "$kind" "${txt:-<no text>}"
        local -a _rl_parts=()
        acceptance_parts_shown_v _rl_parts "$_ACC_SPEC_PARTS"
        for _p in ${_rl_parts[@]+"${_rl_parts[@]}"}; do printf '  %s: %s\n' "${_p%%$'\t'*}" "${_p#*$'\t'}"; done
        ev="$(acceptance_spec_evidence "$design" "$sid" 2>/dev/null | tr '\n' ' ')"
        [[ -n "${ev// /}" ]] && printf -- '  shown by: %s\n' "${ev% }"
        [[ -n "${tfs// /}" ]] && printf -- '  checked by: %s\n' "${tfs% }"
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
    w="$(acceptance_list_wiring "$design" 2>/dev/null | tr '\n' ' ')"
    [[ -n "${w// /}" ]] && printf -- '- The existing file that calls the new code: %s\n' "${w% }"
    return 0
}

# The most characters a section of what the change was for is shown inline
# (#2584, ADR-038): a longer one is named by the file that holds it whole, for
# the lens to read. No section is ever cut.
_RL_CONTEXT_INLINE_MAX=24000

# _rl_context_section_v <var> <heading> <text> <path> <where> — the section,
# its text whole and sanitised; over _RL_CONTEXT_INLINE_MAX, the file that holds
# it (<where>: what to read in it). Empty when <text> is blank.
_rl_context_section_v() {
    local -n _rcs="$1"; local _rcs_t="$3"
    _rcs=""
    [[ -n "${_rcs_t//[[:space:]]/}" ]] || return 0
    if (( ${#_rcs_t} > _RL_CONTEXT_INLINE_MAX )) && [[ -n "$4" ]]; then
        _rcs="## $2"$'\n'"It is too long to show here (${#_rcs_t} characters). Read it whole, as you need it: $5 of $4"$'\n\n'
        return 0
    fi
    _rcs_t="$(printf '%s' "$_rcs_t" | _zbuild_sanitize_for_llm)"
    _rcs="## $2"$'\n'"$_rcs_t"$'\n\n'
}

_rl_context() {
    local f out="" _txt _sec _dir="${artifact_dir:-${artifacts_dir:-${art:-}}}" _if
    # #2364: the issue text and the acceptance contract, found by what they are.
    _if="$(earlier_issue_file "$_dir" "${state_dir:-}" 2>/dev/null || true)"
    _txt=""; [[ -n "$_if" ]] && _txt="$(jq -r '.data.issue_text' "$_if" 2>/dev/null || true)"
    _rl_context_section_v _sec "THE ISSUE (what was asked for)" "$_txt" "$_if" "the .data.issue_text field"; out+="$_sec"
    f="$(earlier_acceptance_contract "$_dir" "${state_dir:-}" 2>/dev/null || true)"
    if [[ -n "$f" && -s "$f" ]] && declare -F acceptance_list_spec_ids >/dev/null 2>&1; then
        # #2269: the requirements as sentences, not the raw block's keys and tags.
        _txt="$(_rl_requirements_readable "$f")"
        _rl_context_section_v _sec "THE REQUIREMENTS (what the change had to meet)" "$_txt" "$f" "the \`\`\`acceptance block"; out+="$_sec"
    fi
    # #1654: what the design DECIDED — so "this is odd" and "this was chosen"
    # can be told apart. Same extractor build honours, every line of it (#2584).
    if [[ -n "$f" && -s "$f" ]] && declare -F design_decisions_prose_v >/dev/null 2>&1; then
        design_decisions_prose_v _txt "$f" 0
        _rl_context_section_v _sec "THE DESIGN DECISIONS (what the design chose, and why)" "$_txt" "$f" "the prose outside its fenced blocks"; out+="$_sec"
    fi
    # #2567 (ADR-038): the design steps build answered not needed, its check
    # accepting the reason — not undone work, unless a lens shows the reason
    # wrong. Read from build's own steps lines (.data.steps, summary.sh): one jq
    # over the earlier JSON outputs, and only when one names a not-needed step.
    local -a _rl_c=() _rl_j=(); local _rl_b
    _eo_candidates_v _rl_c "$_dir" "${state_dir:-}"
    for f in ${_rl_c[@]+"${_rl_c[@]}"}; do
        [[ "$f" == *.json && -s "$f" ]] || continue
        _rl_b=""; IFS= read -r -d '' _rl_b < "$f" || true
        [[ "$_rl_b" == *'"steps"'* && "$_rl_b" == *'not needed'* ]] && _rl_j+=("$f")
    done
    if [[ ${#_rl_j[@]} -gt 0 ]]; then
        _txt="$(jq -r '(.data.steps // empty) | arrays | .[] | strings
            | select(test("^step [0-9]+: not needed — ")) | select(endswith("(not judged)") | not)' \
            "${_rl_j[@]}" 2>/dev/null | awk '!seen[$0]++')"
        _rl_context_section_v _sec "THE DESIGN STEPS BUILD FOUND NOT NEEDED (its check accepted each reason)" "$_txt" \
            "${_rl_j[*]}" "the \"not needed\" lines of .data.steps"; out+="$_sec"
    fi
    # #2302's planned scope is gone: design names no files (#2508, ADR-069 §11).
    printf '%s' "$out"
}
