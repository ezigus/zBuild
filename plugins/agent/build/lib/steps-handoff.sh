#!/usr/bin/env bash
# plugins/agent/build/lib/steps-handoff.sh — build's answers to its own
# findings about the design steps, and a step it hands to another stage
# (#2574, ADR-072 §5). Split from steps.sh (under 500 lines); steps.sh sources
# it, and its functions run in _build_steps_check's scope.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_BUILD_STEPS_HANDOFF_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_STEPS_HANDOFF_LOADED=1

# _build_steps_handed <reply> <artifact_dir> — build's answers to its own
# findings about the steps (#2574, ADR-072 §5), in _build_steps_check's scope:
# fans[n], the answers to step n's findings; newho[n], a not mine that hands
# step n's finding to another stage — "<stages><US><answer><US><finding>". A
# finding is about the step its text starts with (`step N…`, `the check of step
# N…`), as this file writes them.
_build_steps_handed() {
    local -a _bsh=(); local x k kd t n rcv all=""
    zb_answers_collect_v _bsh "$1"
    [[ ${#_bsh[@]} -gt 0 ]] || return 0
    for x in "${_bsh[@]}"; do all+="$x"$'\n'; done
    local -A af=()
    _JUDGE_ANSWER_FINDING=()
    judge_answered_findings_v af "$all" "build=$2/build-summary.json"
    for x in "${_bsh[@]}"; do
        k="${x%%:*}"
        [[ "$k" == "build finding "* || ( -n "${_BUILD_FCODE:-}" && "$k" == "$_BUILD_FCODE-"* ) ]] || continue
        zb_answer_kind_v kd "$x"; [[ -n "$kd" && -n "${af[$k]+x}" ]] || continue
        t="${af[$k]%%$'\x1f'*}"
        [[ "$t" =~ ^(the check of )?step\ ([0-9]{1,6}(\.[0-9]{1,6})?)([^0-9]|$) ]] || continue
        _build_steps_index_v n "${BASH_REMATCH[2]}" || continue
        fans[$n]+="${fans[$n]:+; }${x#*: }"
        [[ "$kd" == "not mine" ]] || continue
        judge_handoff_receivers_v rcv "$_BUILD_STEPS_MANIFEST" "$2" "$k"
        # shellcheck disable=SC2034  # newho is _build_steps_check's
        [[ -n "$rcv" ]] && newho[$n]="$rcv"$'\x1f'"$x"$'\x1f'"$t"
    done
    return 0
}

# _build_steps_keep_carried <artifact_dir> <answer> — while a step waits, the
# finding build handed on stays in build-tests-result.json, so the stage that
# takes it is given it even when this try's reply did not answer it again.
_build_steps_keep_carried() {
    local f="$1/build-tests-result.json" line body="" j
    line="$(_build_test_wrong "ANSWER $2")"; [[ -n "$line" ]] || return 0
    [[ -s "$f" ]] && { IFS= read -r -d '' body < "$f" || true; }
    _judge_json_str_v j "$line"
    [[ "$body" == *"$j"* ]] && return 0
    if [[ -n "$body" ]]; then stage_findings_add "$f" "[{\"text\":$j}]" "${_BUILD_FCODE:-}" || true
    else stage_result_write "$f" fail "build says 1 test(s) are wrong and cannot pass" \
        "{\"findings\":$(stage_findings_json "$1" "${_BUILD_FCODE:-}" <<< "$line")}" 2>/dev/null || true; fi
    return 0
}
