#!/usr/bin/env bash
# scripts/lib/design-steps.sh — what a design asks the change to touch, read
# from design.md by the shell (no program): the areas its ```steps lines name,
# and the words of its ```acceptance block (#2575, ADR-036).
#
# Design's own checks read the step areas (a step names code, never a test);
# the acceptance check asks whether anything asks for a changed file that no
# test checks.
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_DESIGN_STEPS_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_STEPS_LOADED=1

# zb_design_step_areas_v <array> <design_md> — every area the ```steps block's
# lines name after " | areas:", one per entry, in order.
zb_design_step_areas_v() {
    local -n _dsa="$1"; local _l _in=0 _a
    local -a _ar
    _dsa=()
    [[ -f "${2:-}" ]] || return 0
    while IFS= read -r _l || [[ -n "$_l" ]]; do
        _l="${_l%$'\r'}"
        if [[ "$_l" =~ ^'```steps'[[:space:]]*$ ]]; then _in=1; continue; fi
        (( _in == 1 )) || continue
        [[ "$_l" =~ ^'```' ]] && break
        [[ "$_l" == *" | areas:"* ]] || continue
        IFS=',' read -ra _ar <<< "${_l#* | areas:}"
        for _a in ${_ar[@]+"${_ar[@]}"}; do
            _a="${_a#"${_a%%[![:space:]]*}"}"; _a="${_a%"${_a##*[![:space:]]}"}"
            [[ -n "$_a" ]] && _dsa+=("$_a")
        done
    done < "$2"
    return 0
}

# zb_design_asked_v <areas_array> <words_assoc> <design_md> — what the design
# asks for, ready for zb_design_asks_for: each step area as a path (quotes and
# a leading ./ taken off, words after the path dropped), and each word of the
# ```acceptance block — its requirements and its WIRING files — the same way.
zb_design_asked_v() {
    local -n _dqa="$1" _dqw="$2"; local _l _in=0 _w
    local -a _dq_raw=() _dq_ws=()
    _dqa=(); _dqw=()
    [[ -f "${3:-}" ]] || return 0
    zb_design_step_areas_v _dq_raw "$3"
    for _w in ${_dq_raw[@]+"${_dq_raw[@]}"}; do
        read -r _w _ <<< "$_w"
        _zb_design_path_word_v _w "$_w"
        [[ -n "$_w" ]] && _dqa+=("$_w")
    done
    while IFS= read -r _l || [[ -n "$_l" ]]; do
        _l="${_l%$'\r'}"
        if [[ "$_l" == '```acceptance'* ]]; then _in=1; continue; fi
        (( _in == 1 )) || continue
        [[ "$_l" == '```'* ]] && break
        read -ra _dq_ws <<< "$_l"
        for _w in ${_dq_ws[@]+"${_dq_ws[@]}"}; do
            _zb_design_path_word_v _w "$_w"
            [[ -n "$_w" ]] && _dqw["$_w"]=1
        done
    done < "$3"
    return 0
}

# _zb_design_path_word_v <var> <word> — a word as a path: the quotes, brackets
# and trailing punctuation around it taken off, and a leading ./.
_zb_design_path_word_v() {
    local _pw="$2"
    _pw="${_pw#"${_pw%%[!\`\'\"(\[]*}"}"
    _pw="${_pw%"${_pw##*[!\`\'\")\],.;:]}"}"
    _pw="${_pw#./}"
    printf -v "$1" '%s' "$_pw"
}

# zb_design_asks_for <file> <areas_array> <words_assoc> — rc 0 when the design
# asks for a change to <file>: a step's area is the file, a folder holding it
# or a pattern matching it, or a word of the acceptance block is the file.
zb_design_asks_for() {
    local _f="${1#./}" _a
    local -n _daa="$2" _daw="$3"
    [[ -n "${_daw[$_f]+x}" ]] && return 0
    for _a in ${_daa[@]+"${_daa[@]}"}; do
        [[ "$_f" == "$_a" || "$_f" == "${_a%/}/"* ]] && return 0
        # shellcheck disable=SC2053  # the area may be a pattern
        [[ "$_a" == *[*?]* && "$_f" == $_a ]] && return 0
    done
    return 1
}
