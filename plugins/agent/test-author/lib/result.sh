#!/usr/bin/env bash
# plugins/agent/test-author/lib/result.sh — test-author's result and summary:
# the test files it owns, each one's hash, and what it did about its findings
# (ADR-054 §6, #2189, #2186). Split from plugin.sh (#2571: under 500 lines);
# its callers are there.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TEST_AUTHOR_RESULT_LOADED:-}" ]] && return 0
_ZBUILD_TEST_AUTHOR_RESULT_LOADED=1

# _ta_write_result <dir> <outcome> <reason> <n_specs>
# ADR-054 §6 (#2366): one outcome from the engine's list — `pass` when the
# author finished, otherwise how it stopped. A router timeout is not a poor
# authoring pass, it is no authoring pass at all.
_ta_write_result() {
    local dir="$1" o="$2" r="$3" n="${4:-0}" fnd="${5:-[]}" ends="${6:-}"
    mkdir -p "$dir" 2>/dev/null || true
    # #2189: the author REPORTS the testfiles it owns; the engine denies every
    # other stage edits to them from this report (never from design.md by path).
    local _owned="[]" _design _repo="${ZBUILD_REPO_ROOT:-$_TA_ROOT}"
    _design="$(earlier_acceptance_contract "$dir" 2>/dev/null || true)"
    if [[ -s "$_design" ]] && declare -F acceptance_list_testfiles >/dev/null 2>&1; then
        local _ol; _ol="$(acceptance_list_testfiles "$_design" "$_repo" 2>/dev/null || true)"
        _owned="$(jq -Rnc '[inputs | select(length > 0)] | unique' <<< "$_ol" 2>/dev/null || true)"
        [[ -n "$_owned" ]] || _owned="[]"
    fi
    # The author's work lands in the repo, not in this file — so the result
    # carries each testfile's content hash as it stands now. An attempt that
    # wrote changes this artifact; one that wrote nothing leaves it identical,
    # which is what the engine's per-attempt progress check compares (#2186).
    local _tfh="{}" _tf _h
    if [[ "$_owned" != "[]" ]]; then
        local _tf_pairs=""
        while IFS= read -r _tf; do
            [[ -n "$_tf" && -f "$_repo/$_tf" ]] || continue
            _h="$(git hash-object "$_repo/$_tf" 2>/dev/null || true)"
            [[ -n "$_h" ]] && _tf_pairs+="$_tf"$'\t'"$_h"$'\n'
        done < <(jq -r '.[]' <<< "$_owned" 2>/dev/null)
        _tfh="$(jq -Rnc '[inputs | select(length > 0) | split("\t") | {(.[0]): .[1]}] | add // {}' <<< "$_tf_pairs" 2>/dev/null || true)"
        [[ -n "$_tfh" ]] || _tfh="{}"
    fi
    local _data
    # ADR-068 §6: what it did about each finding it received, from its model's
    # ANSWER lines (_ta_collect_answers).
    local _ans; _ans="$(printf '%s\n' "${_TA_ANSWERS[@]+"${_TA_ANSWERS[@]}"}" | jq -Rnc '[inputs | select(length > 0)]' 2>/dev/null || true)"
    [[ -n "$_ans" ]] || _ans="[]"
    # #2574: each answered finding's text travels with the answer.
    local _afj="{}"; zb_answers_findings_json_v _afj _TA_ANSWERS
    _data="$(jq -nc --argjson n "${n:-0}" --argjson o "${_owned:-[]}" --argjson t "$_tfh" --argjson f "$fnd" --argjson a "$_ans" --arg e "$ends" --argjson af "$_afj" \
        --argjson fs "${_ZB_ANS_SHOWN:-0}" --arg un "${_ZB_ANS_MISSING:-}" \
        '{specs_covered: $n, owned_files: $o, testfiles: $t}
         + (if ($f | length) > 0 then {findings: $f} else {} end)
         + (if ($a | length) > 0 then {answers: $a} else {} end)
         + (if ($af | length) > 0 then {answer_findings: $af} else {} end)
         + {findings_shown: $fs}
         + (if $un != "" then {unanswered: ($un | split("\n"))} else {} end)
         + (if $e == "ends_round" then {ends_round: true} else {} end)')"
    if ! stage_result_write "$dir/test-author-result.json" "$o" "$r" "$_data"; then
        _ta_emit "test_author.result.write_failed" "dir=$dir"
    fi
    # The test files and what each covers, for the stages after this one: build
    # starts from them instead of running them to find them (#1801 run 40390919951).
    local _tf_lines="" _tf_ids=""
    if [[ -s "$_design" ]] && declare -F acceptance_list_spec_ids >/dev/null 2>&1; then
        local -A _tf_specs=() _tf_by=()
        local -a _tf_order=()
        local _sid _f
        acceptance_spec_files_v _tf_by "$_design" "$_repo"
        while IFS= read -r _sid; do
            [[ -n "$_sid" ]] || continue
            _tf_ids+="${_tf_ids:+, }$_sid"
            for _f in ${_tf_by[$_sid]:-}; do
                [[ -n "${_tf_specs[$_f]+x}" ]] || _tf_order+=("$_f")
                _tf_specs[$_f]+="${_tf_specs[$_f]:+, }$_sid"
            done
        done < <(acceptance_list_spec_ids "$_design" 2>/dev/null || true)
        for _f in ${_tf_order[@]+"${_tf_order[@]}"}; do _tf_lines+=$'\n'"- ${_f} — ${_tf_specs[$_f]}"; done
    fi
    # #2476 (ADR-064 §4): a passing try's line names the SPECs it wrote tests
    # for; one that did not pass says why (its findings reach the row).
    local _sum_body="" _sum_head="$r"
    [[ "$o" == pass && -n "$_tf_ids" ]] && _sum_head="tests for ${_tf_ids}"
    if [[ -n "$_tf_lines" ]]; then
        _sum_body="- the test files, and the requirements each covers:${_tf_lines}"
        _sum_body+=$'\n'"- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written."
    fi
    local _a; zb_answers_summary_v _a _TA_ANSWERS
    _sum_body+="${_sum_body:+$'\n'}$_a"
    stage_summary_write "$dir/test-author-summary.md" "test-author" "$o" "$_sum_head" "$_sum_body"
}
