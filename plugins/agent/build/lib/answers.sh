#!/usr/bin/env bash
# plugins/agent/build/lib/answers.sh — build's answers to the findings it is
# given (ADR-068 §6): those that say a test is wrong, written as findings for
# the stage that owns the tests, and every answer as its result keeps it.
# Split from summary.sh (#2574: under 500 lines); summary.sh sources it.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_BUILD_ANSWERS_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_ANSWERS_LOADED=1
# shellcheck source=../../../../scripts/lib/stage-answers.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/stage-answers.sh"
# shellcheck source=../../../../scripts/lib/test-paths.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/test-paths.sh"
# shellcheck source=../../../../scripts/lib/stage-handoff.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/stage-handoff.sh" 2>/dev/null || true
# shellcheck source=../../../../scripts/lib/item-ids.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/item-ids.sh"
# #2574 (ADR-068 §5): the code build's findings' ids take (BUFND).
_BUILD_FCODE=""; zb_finding_code_v _BUILD_FCODE "${BASH_SOURCE[0]%/*}/../manifest.yaml"

# _build_test_wrong <response_text> — build's answers that a test is wrong, one
# per line, each `<the finding's id>: <test file>: <why>` (#2441). Read from
# `ANSWER <its id>: wrong — the test is wrong: <file>: <why>`, and (#2508) from
# `ANSWER <its id>: not mine — the test must change: <file>: <why>` — a test
# that pins what this change alters is the test author's to change, never
# build's. #2599: and from a `not mine` in any words that names a test file or
# test-author. #2527: the answers are the ones zb_answers_collect_v reads, so a
# finding named as listed, "(opened by …)" and all, or in the form before ids
# (#2574), is read. Read by the shell: it runs on every try (ADR-065).
_build_test_wrong() {
    local a re had=0
    local -a _btw=()
    zb_answers_collect_v _btw "${1:-}"
    re='^[^:]+:.*the[[:space:]]+test[[:space:]]+(is[[:space:]]+wrong|must[[:space:]]+change)[[:space:]]*:[[:space:]]*(.+)$'
    shopt -q nocasematch && had=1
    shopt -s nocasematch
    local w t tf why _btw_ta=""; local -a _btw_w=()
    zb_finding_code_v _btw_ta "${BASH_SOURCE[0]%/*}/../../test-author/manifest.yaml"
    for a in ${_btw[@]+"${_btw[@]}"}; do
        if [[ "$a" =~ $re ]]; then
            printf '%s: %s\n' "${a%%:*}" "${BASH_REMATCH[2]%"${BASH_REMATCH[2]##*[![:space:]]}"}"
            continue
        fi
        # #2599 (ADR-068 §6): a "not mine" in any words that says the tests
        # can fix it (zb_not_mine_target_v) is the tests' to fix. #2532 run
        # 45231040380: "not mine — … lives in tests/unit/…; the test-author
        # stage must fix it" was in no form read, and reached no one. One
        # test-author handed to build is never handed back (it goes to design:
        # _build_write_handoffs), and build's own check's are the old path's.
        why="${a#*:}"; why="${why#"${why%%[![:space:]]*}"}"
        [[ "$why" =~ ^not[[:space:]]+mine ]] || continue
        [[ -n "$_btw_ta" && "${a%%:*}" == "$_btw_ta"-* ]] && continue
        [[ -n "$_BUILD_FCODE" && "${a%%:*}" == "$_BUILD_FCODE"-* ]] && continue
        why="${why:9}"; why="${why#"${why%%[![:space:]—-]*}"}"
        zb_not_mine_target_v t "$why"
        [[ "$t" == test ]] || continue
        tf=""; _btw_w=()
        read -ra _btw_w <<< "$why"   # no glob: a word like tests/* stays a word
        for w in ${_btw_w[@]+"${_btw_w[@]}"}; do
            w="${w//[\`\'\"(),;]/}"; w="${w%.}"; w="${w%:}"; w="${w#./}"
            [[ "$w" == */* ]] && zb_is_test_path "$w" && { tf="$w"; break; }
        done
        printf '%s: %s%s%s\n' "${a%%:*}" "${tf:+$tf: }" "$why" "${_ZB_ANS_FINDING[${a%%:*}]:+ — the finding: ${_ZB_ANS_FINDING[${a%%:*}]//$'\n'/ }}"
    done
    (( had )) || shopt -u nocasematch
}

# _build_write_handoffs <artifact_dir> [reply] — every try (#2599, ADR-068 §6):
# the tests' "not mine" answers to test-author (_build_write_test_findings), and
# to design (build-design-result.json, topic design-findings) each "not mine"
# that says design must fix it, and each to a finding test-author handed to
# build — never handed back. Each keeps its id and the finding's text. Written
# fresh each try, as build-tests-result.json is: a try with none leaves no
# file, so no earlier try's hand-offs linger.
declare -gA _ZB_ANS_FINDING 2>/dev/null || true
_build_write_handoffs() {
    local art="${1%/}" reply="${2-${_ROUTE_LOOP_LAST_RESPONSE:-}}" a why t ta="" lines=""
    local -a ans=()
    _ROUTE_LOOP_LAST_RESPONSE="$reply" _build_write_test_findings "$art"
    zb_finding_code_v ta "${BASH_SOURCE[0]%/*}/../../test-author/manifest.yaml"
    zb_answers_collect_v ans "$reply"
    for a in ${ans[@]+"${ans[@]}"}; do
        why="${a#*:}"; why="${why#"${why%%[![:space:]]*}"}"
        [[ "$why" =~ ^[Nn]ot[[:space:]]+mine ]] || continue
        # Build's own findings are its to fix — except an untraced file (#2629,
        # ADR-075 §2): design adds the step that asks for it.
        if [[ -n "$_BUILD_FCODE" && "${a%%:*}" == "$_BUILD_FCODE"-* ]]; then
            _build_own_finding_text_v t "${a%%:*}" "$art"
            [[ "$t" == *"${_BUILD_TRACE_OWN:-traces to no design step}"* ]] || continue
            _ZB_ANS_FINDING["${a%%:*}"]="$t"
        fi
        why="${why:9}"; why="${why#"${why%%[![:space:]—-]*}"}"
        zb_not_mine_target_v t "$why"
        if [[ "$t" == design || ( -n "$ta" && "${a%%:*}" == "$ta"-* ) ]]; then
            lines+="${a%%:*}: build answered not mine: $why${_ZB_ANS_FINDING[${a%%:*}]:+ — the finding: ${_ZB_ANS_FINDING[${a%%:*}]//$'\n'/ }}"$'\n'
        fi
    done
    [[ -e "$art/build-design-result.json" ]] && rm -f "$art/build-design-result.json"
    if [[ -n "$lines" ]] && declare -F stage_findings_add >/dev/null 2>&1; then
        stage_findings_add "$art/build-design-result.json" \
            "$(printf '%s' "$lines" | jq -Rnc '[inputs | select(length > 0) | {text: .}]')" "$_BUILD_FCODE" || true
    fi
    return 0
}

# _build_own_finding_text_v <var> <id> <artifact_dir> — the text of build's own
# finding <id>, from its latest result, by the shell: the finding a not mine
# answers, read only when such an answer names one of build's own ids.
_build_own_finding_text_v() {
    local -n _boft="$1"; local _s="" _re
    _boft=""
    [[ -s "$3/build-summary.json" ]] || return 0
    IFS= read -r -d '' _s < "$3/build-summary.json" || true
    _re='"text":"'"$ZB_JSON_STR_RE"'"[^{}]*"id":"'"$2"'"'
    [[ "$_s" =~ $_re ]] || { _re='"id":"'"$2"'"[^{}]*"text":"'"$ZB_JSON_STR_RE"'"'; [[ "$_s" =~ $_re ]] || return 0; }
    # The text as it was written, its JSON escapes read (review on #2629).
    zb_json_unescape_v _boft "${BASH_REMATCH[1]}"
    return 0
}

# _build_write_test_findings <artifact_dir> — build-tests-result.json (ADR-068
# §6, ADR-071 §1, #2441): build's answers that a test is wrong, as findings on
# topic test-findings (#2569), so the stage that owns the tests is given them. Nothing
# else of build's is in it: build's code stays on change. A try with no such
# answer leaves no file, so no earlier try's answers are passed on.
_build_write_test_findings() {
    local out="${1%/}/build-tests-result.json" lines n=0 l
    lines="$(_build_test_wrong "${_ROUTE_LOOP_LAST_RESPONSE:-}")"
    if [[ -z "$lines" ]]; then
        [[ -e "$out" ]] && rm -f "$out"
        return 0
    fi
    while IFS= read -r l; do [[ -n "$l" ]] && n=$((n + 1)); done <<< "$lines"
    stage_result_write "$out" fail "build says $n test(s) are wrong and cannot pass" \
        "{\"findings\":$(printf '%s\n' "$lines" | stage_findings_json "${1%/}" "$_BUILD_FCODE")}" 2>/dev/null || true
}

# _build_answers_json_v <var> [findings_var] — build's answers to the findings
# its prompt showed it, as JSON, as test-author keeps its own (#2464): one it did
# not give stays open (zb_answers_finish, ADR-068 §6). Kept in _BUILD_ANSWERS
# for its summary; no process when there are none (ADR-065 §5). [findings_var]
# gets each answered finding's text, by its id (#2574: it travels with the
# answer).
_BUILD_ANSWERS=()
_build_answers_json_v() {
    local -n _baj="$1"; local _bap="" _bapf="${prompt_input_file:-${artifact_dir:+$artifact_dir/build-prompt.txt}}"
    _baj="[]"; _BUILD_ANSWERS=()
    [[ -n "$_bapf" && -f "$_bapf" ]] && { IFS= read -r -d '' _bap < "$_bapf" || true; }
    declare -F zb_answers_finish >/dev/null 2>&1 && zb_answers_finish _BUILD_ANSWERS "$_bap" "${_ROUTE_LOOP_LAST_RESPONSE:-}" "${artifact_dir:+$artifact_dir/build-summary.json}"
    if [[ -n "${2:-}" ]]; then local -n _bajf="$2"; zb_answers_findings_json_v _bajf _BUILD_ANSWERS; fi
    [[ ${#_BUILD_ANSWERS[@]} -gt 0 ]] || return 0
    _baj="$(printf '%s\n' "${_BUILD_ANSWERS[@]}" | jq -Rnc '[inputs | select(length > 0)]' 2>/dev/null)" || _baj="[]"
    [[ -n "$_baj" ]] || _baj="[]"
}
