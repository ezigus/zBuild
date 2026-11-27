#!/usr/bin/env bash
# plugins/agent/build/lib/steps-trace.sh — every file build's round changed
# traces to the work build was handed (#2629, ADR-075 §2): a design step whose
# areas hold it, or a finding build answered done, naming the file. Read by
# script, by name.
#
# On #1722 run 45872552515 build changed scripts/lib/acceptance-block.sh — in no
# step's areas — to make a test pass, and nothing said so until nine of
# design's tests failed.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_BUILD_STEPS_TRACE_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_STEPS_TRACE_LOADED=1
# shellcheck source=../../../../scripts/lib/trace.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/trace.sh"

# _build_trace_check <files> <repo> — <files>, one a line, are the files the
# round changed (round.sh: every try's). Its done answers are _BUILD_ANSWERS
# (answers.sh: this try's, and those an earlier try's result carries — what any
# try did counts, ADR-068 §6). Each file outside the test folders that no
# step's areas hold and no done answer names is a finding in
# _BUILD_STEP_FINDINGS. With no steps there is nothing to trace to.
_build_trace_check() {
    local files="$1" repo="${2:-}" f n kind named="" a msg
    (( ${#_BUILD_STEP_DESC[@]} > 0 )) || return 0
    for a in ${_BUILD_ANSWERS[@]+"${_BUILD_ANSWERS[@]}"}; do
        zb_answer_kind_v kind "$a"
        [[ "$kind" == done ]] && named+=" ${a#*:} "
    done
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        zb_is_test_path "$f" "$repo" && continue
        for (( n = 0; n < ${#_BUILD_STEP_DESC[@]}; n++ )); do
            zb_trace_covered "$f" "${_BUILD_STEP_AREAS[n]:-}" && continue 2
        done
        [[ "$named" == *"$f"* ]] && continue
        zb_trace_finding_v msg "$f" "design step and no finding you answered done" "design, with a step whose areas hold it,"
        _BUILD_STEP_FINDINGS+=("$msg (a done answer to a finding names each file it changed: \`ANSWER <its id>: done — <file> | <a line you added>\`)")
    done <<< "$files"
    return 0
}

# _build_json_strings_v <var> <JSON array of strings> — its strings, one a
# line, read by the shell (no process a try): files_changed_json as plugin.sh
# and round.sh write it, a quote or backslash in a name escaped.
_build_json_strings_v() {
    local -n _bjs="$1"; local rest="$2" one
    local re='^[^"]*"(([^"\\]|\\.)*)"(.*)$'
    _bjs=""
    while [[ "$rest" =~ $re ]]; do
        one="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[3]}"
        one="${one//\\\"/\"}"; one="${one//\\\\/\\}"
        _bjs+="$one"$'\n'
    done
}
