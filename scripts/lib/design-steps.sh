#!/usr/bin/env bash
# scripts/lib/design-steps.sh — a design's ```steps block, read one way, and
# what the design asks the change to touch (#2575, ADR-036).
#
# One parser (zb_design_step_lines_v) reads the steps for design's writer
# (design-steps.json), design's own checks, and the acceptance check. What a
# design asks for is each step's areas and the words of its ```acceptance
# block, matched to a changed file by one rule (zb_design_covered_v).
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_DESIGN_STEPS_LOADED:-}" ]] && return 0
_ZBUILD_DESIGN_STEPS_LOADED=1

# zb_design_step_lines_v <array> <design_md> — each step of the ```steps block,
# in order, its list marker taken off: "<what to do> | areas: <areas>". A step
# whose words or areas carry on to the next line is one entry (#2460).
zb_design_step_lines_v() {
    local -n _dsl="$1"; local _dsl_l _dsl_in=0 _dsl_c
    _dsl=()
    [[ -f "${2:-}" ]] || return 0
    while IFS= read -r _dsl_l || [[ -n "$_dsl_l" ]]; do
        _dsl_l="${_dsl_l%$'\r'}"
        if [[ "$_dsl_l" =~ ^'```steps'[[:space:]]*$ ]]; then _dsl_in=1; continue; fi
        (( _dsl_in == 1 )) || continue
        [[ "$_dsl_l" =~ ^'```'[[:space:]]*$ ]] && break
        if [[ "$_dsl_l" =~ ^[[:space:]]*[-*0-9.]+[[:space:]]+(.*[^[:space:]]) ]]; then
            _dsl+=("${BASH_REMATCH[1]}")
        elif [[ -n "${_dsl_l// }" && ${#_dsl[@]} -gt 0 ]]; then
            _dsl_c="${_dsl_l#"${_dsl_l%%[![:space:]]*}"}"
            _dsl[-1]+=" ${_dsl_c%"${_dsl_c##*[![:space:]]}"}"
        fi
    done < "$2"
    return 0
}

# zb_design_write_steps <design_md> <out_json> — the steps as
# {title, steps:[{id, description, areas}]}. A design with no steps writes none
# (and removes an earlier one, so a stale list is never read as this design's).
zb_design_write_steps() {
    local design="$1" out="$2" title
    local -a lines=()
    zb_design_step_lines_v lines "$design"
    if [[ ${#lines[@]} -eq 0 ]]; then rm -f "$out" 2>/dev/null; return 0; fi
    title="$(grep -m1 -E '^# ' "$design" 2>/dev/null || true)"; title="${title#\# }"
    printf '%s\n' "${lines[@]}" | jq -Rsc --arg t "$title" '
        split("\n") | map(select(length > 0))
        | [.[] | split(" | areas:") as $p
            | {description: ($p[0] | gsub("^\\s+|\\s+$"; "")),
               areas: (($p[1] // "") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}]
        | {title: $t, steps: [to_entries[] | {id: "step-\(.key + 1)"} + .value]}' \
        | atomic_write "$out" || rm -f "$out" 2>/dev/null
    return 0
}

# zb_design_step_areas_v <array> <design_md> — every area the steps name after
# " | areas:", one per entry, in order.
zb_design_step_areas_v() {
    local -n _dsa="$1"; local _dsa_s _dsa_a
    local -a _dsa_lines=() _dsa_ar=()
    _dsa=()
    zb_design_step_lines_v _dsa_lines "${2:-}"
    for _dsa_s in ${_dsa_lines[@]+"${_dsa_lines[@]}"}; do
        [[ "$_dsa_s" == *" | areas:"* ]] || continue
        IFS=',' read -ra _dsa_ar <<< "${_dsa_s#* | areas:}"
        for _dsa_a in ${_dsa_ar[@]+"${_dsa_ar[@]}"}; do
            _dsa_a="${_dsa_a#"${_dsa_a%%[![:space:]]*}"}"; _dsa_a="${_dsa_a%"${_dsa_a##*[![:space:]]}"}"
            [[ -n "$_dsa_a" ]] && _dsa+=("$_dsa_a")
        done
    done
    return 0
}

# _zb_design_path_v <var> <word> — a word as a path, or empty when it names
# none: quotes and brackets around it, and what follows a path — :func, #func,
# (...), 's, trailing punctuation — taken off, and a leading ./. A `]` that
# closes a `[` in the word is kept (scripts/[ab].sh).
_zb_design_path_v() {
    local _dp="$2"
    _dp="${_dp#"${_dp%%[!\`\'\"(<]*}"}"
    _dp="${_dp%%(*}"; _dp="${_dp%%:*}"; _dp="${_dp%%#*}"
    _dp="${_dp%\'s}"; _dp="${_dp%’s}"
    while [[ -n "$_dp" ]]; do
        case "$_dp" in
            *\`|*\'|*\"|*\)|*,|*.|*\;|*\>) _dp="${_dp%?}" ;;
            *\]) [[ "$_dp" == *\[* ]] && break; _dp="${_dp%?}" ;;
            *) break ;;
        esac
    done
    _dp="${_dp#./}"
    # A path has a folder or an extension.
    [[ "$_dp" == */* || "$_dp" == ?*.?* ]] || _dp=""
    printf -v "$1" '%s' "$_dp"
}

# zb_design_asked_v <steps_array> <words_assoc> <design_md> — what the design
# asks for: each path a step's areas name, as "<step number><TAB><path>" (a
# path anywhere in the areas' words), and each path the ```acceptance block
# names. <words_assoc> must be an associative array (rc 2 otherwise, nothing
# written). No steps block: <steps_array> is empty.
zb_design_asked_v() {
    local -n _dqs="$1" _dqw="$2"
    # An empty array reads as unset under set -u, so its kind is read without it.
    local _dq_o="$-" _dq_k
    set +u; _dq_k="${_dqw@a}"; [[ "$_dq_o" == *u* ]] && set -u
    [[ "$_dq_k" == *A* ]] || return 2
    local _dq_l _dq_in=0 _dq_w _dq_n=0 _dq_s
    local -a _dq_lines=() _dq_ws=()
    _dqs=(); _dqw=()
    [[ -f "${3:-}" ]] || return 0
    zb_design_step_lines_v _dq_lines "$3"
    for _dq_s in ${_dq_lines[@]+"${_dq_lines[@]}"}; do
        _dq_n=$(( _dq_n + 1 ))
        [[ "$_dq_s" == *" | areas:"* ]] || continue
        _dq_s="${_dq_s#* | areas:}"
        read -ra _dq_ws <<< "${_dq_s//,/ }"
        for _dq_w in ${_dq_ws[@]+"${_dq_ws[@]}"}; do
            _zb_design_path_v _dq_w "$_dq_w"
            [[ -n "$_dq_w" ]] && _dqs+=("$_dq_n"$'\t'"$_dq_w")
        done
    done
    while IFS= read -r _dq_l || [[ -n "$_dq_l" ]]; do
        _dq_l="${_dq_l%$'\r'}"
        if [[ "$_dq_l" == '```acceptance'* ]]; then _dq_in=1; continue; fi
        (( _dq_in == 1 )) || continue
        [[ "$_dq_l" == '```'* ]] && break
        read -ra _dq_ws <<< "$_dq_l"
        for _dq_w in ${_dq_ws[@]+"${_dq_ws[@]}"}; do
            _zb_design_path_v _dq_w "$_dq_w"
            [[ -n "$_dq_w" ]] && _dqw["$_dq_w"]=1
        done
    done < "$3"
    return 0
}

# _zb_design_path_covers <file> <path> <changed_array> — rc 0 when <path>, as a
# design names it, is <file>: the same path; a folder holding it; a pattern
# matching it whose part before the first wildcard holds a name (so *, ** and
# *.sh match nothing); or a bare file name that is <file>'s and no other
# changed file's.
_zb_design_path_covers() {
    local _pf="${1#./}" _pp="$2" _pc _pn=0 _pre
    local -n _pch="$3"
    [[ "$_pf" == "$_pp" ]] && return 0
    if [[ "$_pp" == *[*?[]* ]]; then
        _pre="${_pp%%[*?[]*}"
        [[ -n "${_pre//[.\/]/}" ]] || return 1
        # shellcheck disable=SC2053  # the path is a pattern
        [[ "$_pf" == $_pp ]]; return
    fi
    if [[ "$_pp" == */* ]]; then
        [[ -n "${_pp//\//}" && "$_pf" == "${_pp%/}/"* ]]; return
    fi
    [[ "${_pf##*/}" == "$_pp" ]] || return 1
    for _pc in ${_pch[@]+"${_pch[@]}"}; do [[ "${_pc##*/}" == "$_pp" ]] && _pn=$(( _pn + 1 )); done
    (( _pn == 1 ))
}

# zb_design_covered_v <var> <file> <steps_array> <words_assoc> <changed_array>
# — what asks for a change to <file>: "spec" when a word of the acceptance block
# names it (a SPEC, or a WIRING file), "step:<n>" when only step <n>'s areas do,
# empty when nothing does.
zb_design_covered_v() {
    local -n _dcv="$1"; local _dc_f="$2" _dc_e _dc_w
    local -n _dc_s="$3" _dc_ws="$4"
    _dcv=""
    for _dc_w in "${!_dc_ws[@]}"; do
        _zb_design_path_covers "$_dc_f" "$_dc_w" "$5" && { _dcv=spec; return 0; }
    done
    for _dc_e in ${_dc_s[@]+"${_dc_s[@]}"}; do
        _zb_design_path_covers "$_dc_f" "${_dc_e#*$'\t'}" "$5" && { _dcv="step:${_dc_e%%$'\t'*}"; return 0; }
    done
    return 0
}
