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
# round changed (_build_trace_files_v). What build was handed is the design's
# steps (_BUILD_STEP_AREAS) and the findings its prompt showed it
# (_ZB_ANS_FINDING, set by zb_answers_finish); its answers are _BUILD_ANSWERS —
# this try's, and those an earlier try's result carries (ADR-068 §6). A file
# traces when a step's areas hold it, or when a done answer to a finding build
# was shown names it in its slot, `done — <file> | <a line you added>`, exactly
# (review on #2629: not a file named in its words, not part of another path,
# not an answer to a finding it was never shown, nor to its own untraced
# finding). Each file outside the test folders that traces to neither is a
# finding in _BUILD_STEP_FINDINGS — unless build answered that finding not
# mine, naming design: then it waits for design (_BUILD_STEP_WAITING) and the
# round ends. With no steps there is nothing to trace to.
_BUILD_TRACE_OWN="traces to no design step and no finding you answered done"
_build_trace_check() {
    local files="$1" repo="${2:-}" f n kind a id why slot t t2="" msg
    (( ${#_BUILD_STEP_DESC[@]} > 0 )) || return 0
    local -A named=() waits=()
    for a in ${_BUILD_ANSWERS[@]+"${_BUILD_ANSWERS[@]}"}; do
        id="${a%%:*}"; t=""
        if [[ -n "${_ZB_ANS_FINDING[$id]+x}" ]]; then t="${_ZB_ANS_FINDING[$id]}"
        # Its own finding, from its latest result (the one Previous work shows).
        elif [[ -n "${_BUILD_FCODE:-}" && "$id" == "$_BUILD_FCODE"-* ]]; then
            _build_own_finding_text_v t "$id" "${artifact_dir:-}"
            [[ "$t" == *"$_BUILD_TRACE_OWN"* ]] || continue
        else continue; fi
        zb_answer_kind_v kind "$a"
        if [[ "$t" == *"$_BUILD_TRACE_OWN"* ]]; then
            # Its own untraced finding: only a not mine naming design moves it.
            [[ "$kind" == "not mine" ]] || continue
            why="${a#*:}"; zb_not_mine_target_v t2 "$why"
            [[ "${t2:-}" == design ]] && waits["${t%% "$_BUILD_TRACE_OWN"*}"]="$a"
            continue
        fi
        [[ "$kind" == "done" ]] || continue
        _build_trace_slot_v slot "$a"
        [[ -n "$slot" ]] && named["$slot"]=1
    done
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        zb_is_test_path "$f" "$repo" && continue
        for (( n = 0; n < ${#_BUILD_STEP_DESC[@]}; n++ )); do
            zb_trace_covered "$f" "${_BUILD_STEP_AREAS[n]:-}" && continue 2
        done
        [[ -n "${named[$f]+x}" ]] && continue
        if [[ -n "${waits[$f]+x}" ]]; then
            _BUILD_STEP_WAITING+=("$f: handed to design, which must add a step whose areas hold it — ${waits[$f]#*:}")
            continue
        fi
        zb_trace_finding_v msg "$f" "design step and no finding you answered done" "design, with a step whose areas hold it,"
        _BUILD_STEP_FINDINGS+=("$msg (a done answer to a finding names each file it changed: \`ANSWER <its id>: done — <file> | <a line you added> — <what you changed>\`)")
    done <<< "$files"
    return 0
}

# _build_trace_slot_v <var> <answer> — the file in a done answer's slot,
# `<id>: done — <file> | <line>`: what stands between the word done and the
# first bar, its marks taken off; empty when there is no bar.
_build_trace_slot_v() {
    local -n _bts="$1"; local _a="${2#*:}" _re='^[[:space:]*_`]*done(.*)$'
    _bts=""
    [[ "${_a,,}" =~ $_re ]] || return 0
    _a="${_a:${#_a}-${#BASH_REMATCH[1]}}"
    [[ "$_a" == *"|"* ]] || return 0
    _a="${_a%%|*}"
    while :; do
        _a="${_a#"${_a%%[![:space:]]*}"}"
        # A dash, a colon, or the mark that opens a quoted `<file> | <line>`.
        case "$_a" in —*) _a="${_a#—}" ;; –*) _a="${_a#–}" ;; [-:*\`\"\']*) _a="${_a:1}" ;; *) break ;; esac
    done
    _a="${_a%"${_a##*[![:space:]]}"}"
    zb_trace_path_v _bts "$_a"
}

# _build_trace_files_v <var> <repo> <base> — the files the round changed, one
# a line: the working tree, intent-to-add files included, against the round's
# base (round.sh: before its first pass), so every pass's commits are in it.
# One git call, NUL-separated (a name with a space or a quote is read whole);
# a moved file is its new path (#2629 review: a rename's old path is no change
# of its own), a removed file is its path.
_build_trace_files_v() {
    local -n _btf="$1"; local repo="$2" base="${3:-HEAD}" st p
    _btf=""
    [[ -n "$repo" ]] || return 0
    while IFS= read -r -d '' st; do
        case "$st" in
            R*|C*) IFS= read -r -d '' p; IFS= read -r -d '' p ;;
            *) IFS= read -r -d '' p ;;
        esac
        [[ -n "$p" ]] && _btf+="$p"$'\n'
    done < <(git -C "$repo" diff -z --name-status -M "$base" -- 2>/dev/null)
    return 0
}
