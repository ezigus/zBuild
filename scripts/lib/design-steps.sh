#!/usr/bin/env bash
# scripts/lib/design-steps.sh — a design's ```steps block, read one way, and
# whether it names a changed file (#2575, ADR-036).
#
# A step names the SPECs it serves after " | serves:" (#2579, ADR-068): a step
# is a summary of part of them, and its checks are shown them.
#
# One parser (zb_design_step_lines_v) reads the steps for design's writer
# (design-steps.json), design's own checks, and the acceptance check. A file
# is named when the design names it anywhere (zb_design_names_v) — generous on
# purpose: what is named nowhere is taken out, so a miss would delete work.
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

# zb_design_step_split <step> — one step line's parts: _ZB_STEP_DESC, what to
# do; _ZB_STEP_AREAS, the text after " | areas:"; _ZB_STEP_SERVES, the ids
# after " | serves:", space separated, each once: a trailing [tag] or brackets
# taken off, a word that is no id (_ACCEPTANCE_ID_ERE) set aside. Either part
# may come first; each runs to the other or the end.
_ZB_STEP_DESC="" _ZB_STEP_AREAS="" _ZB_STEP_SERVES=""
zb_design_step_split() {
    local s="$1" a="" v="" w
    [[ -n "${_ACCEPTANCE_ID_ERE:-}" ]] || source "${BASH_SOURCE[0]%/*}/acceptance-block.sh" 2>/dev/null || true
    _ZB_STEP_DESC="${s%% | areas:*}"; _ZB_STEP_DESC="${_ZB_STEP_DESC%% | serves:*}"
    [[ "$s" == *" | areas:"* ]] && { a="${s#* | areas:}"; a="${a%% | serves:*}"; }
    [[ "$s" == *" | serves:"* ]] && { v="${s#* | serves:}"; v="${v%% | areas:*}"; }
    _ZB_STEP_DESC="${_ZB_STEP_DESC#"${_ZB_STEP_DESC%%[![:space:]]*}"}"; _ZB_STEP_DESC="${_ZB_STEP_DESC%"${_ZB_STEP_DESC##*[![:space:]]}"}"
    _ZB_STEP_AREAS="$a" _ZB_STEP_SERVES=""
    local -a ws=(); IFS=$' \t\n' read -ra ws <<< "${v//[,;]/ }"
    for w in ${ws[@]+"${ws[@]}"}; do
        w="${w#\[}"; w="${w%.}"; w="${w%\]}"; [[ "$w" == *\[* ]] && w="${w%%\[*}"
        [[ "$w" =~ ^${_ACCEPTANCE_ID_ERE}$ && " $_ZB_STEP_SERVES " != *" $w "* ]] && _ZB_STEP_SERVES+="${_ZB_STEP_SERVES:+ }$w"
    done
    return 0
}

# zb_design_write_steps <design_md> <out_json> — the steps as
# {title, steps:[{id, description, areas, serves}], specs:{<id>: <text>}}:
# specs holds each served SPEC as a model is shown it (acceptance_spec_render_v),
# so a step's check is shown what the step summarizes (#2579). A design with no
# steps writes none (and removes an earlier one, so a stale list is never read
# as this design's).
zb_design_write_steps() {
    local design="$1" out="$2" title l rows="" specs="" blk="" id txt all=""
    local -a lines=()
    local -A seen=()
    zb_design_step_lines_v lines "$design"
    if [[ ${#lines[@]} -eq 0 ]]; then rm -f "$out" 2>/dev/null; return 0; fi
    title="$(grep -m1 -E '^# ' "$design" 2>/dev/null || true)"; title="${title#\# }"
    for l in "${lines[@]}"; do
        zb_design_step_split "$l"
        l="${_ZB_STEP_DESC//[$'\x1e\x1f']/ }"$'\x1f'"${_ZB_STEP_AREAS//[$'\x1e\x1f']/ }"
        rows+="$l"$'\x1f'"$_ZB_STEP_SERVES"$'\x1e'
        all+="${_ZB_STEP_SERVES:+ $_ZB_STEP_SERVES}"
    done
    if [[ -n "$all" ]]; then
        declare -F acceptance_spec_render_v >/dev/null 2>&1 \
            || source "${BASH_SOURCE[0]%/*}/acceptance-block.sh" 2>/dev/null || true
        blk="$(extract_acceptance_block "$design" 2>/dev/null)" || blk=""
        local -a ids=(); IFS=$' \t\n' read -ra ids <<< "$all"
        for id in "${ids[@]}"; do
            [[ -z "${seen[$id]+x}" ]] || continue
            seen[$id]=1; txt=""
            acceptance_spec_render_v txt "$blk" "$id" 2>/dev/null || txt=""
            [[ -n "$txt" ]] && specs+="$id"$'\x1f'"${txt//$'\x1e'/ }"$'\x1e'
        done
    fi
    jq -nc --arg t "$title" --arg rows "$rows" --arg specs "$specs" '
        def trim: gsub("^\\s+|\\s+$"; "");
        [$rows | split("\u001e")[] | select(length > 0) | split("\u001f")
          | {description: (.[0] | trim),
             areas: ((.[1] // "") | split(",") | map(trim) | map(select(length > 0))),
             serves: ((.[2] // "") | split(" ") | map(select(length > 0)))}] as $s
        | {title: $t, steps: [$s | to_entries[] | {id: "step-\(.key + 1)"} + .value],
           specs: ([$specs | split("\u001e")[] | select(length > 0) | split("\u001f") | {(.[0]): .[1]}] | add // {})}' \
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
        zb_design_step_split "$_dsa_s"
        IFS=',' read -ra _dsa_ar <<< "$_ZB_STEP_AREAS"
        for _dsa_a in ${_dsa_ar[@]+"${_dsa_ar[@]}"}; do
            _dsa_a="${_dsa_a#"${_dsa_a%%[![:space:]]*}"}"; _dsa_a="${_dsa_a%"${_dsa_a##*[![:space:]]}"}"
            [[ -n "$_dsa_a" ]] && _dsa+=("$_dsa_a")
        done
    done
    return 0
}

# zb_design_steps_unmarked_v <array> <design_md> — each line of the ```steps
# block that names areas (" | areas:") but has no list marker: the parser reads
# a line with no marker as the step above it carrying on.
zb_design_steps_unmarked_v() {
    local -n _dsu="$1"; local _dsu_l _dsu_in=0
    _dsu=()
    [[ -f "${2:-}" ]] || return 0
    while IFS= read -r _dsu_l || [[ -n "$_dsu_l" ]]; do
        _dsu_l="${_dsu_l%$'\r'}"
        if [[ "$_dsu_l" =~ ^'```steps'[[:space:]]*$ ]]; then _dsu_in=1; continue; fi
        (( _dsu_in == 1 )) || continue
        [[ "$_dsu_l" =~ ^'```'[[:space:]]*$ ]] && break
        [[ "$_dsu_l" == *" | areas:"* && ! "$_dsu_l" =~ ^[[:space:]]*[-*0-9.]+[[:space:]]+ ]] && _dsu+=("$_dsu_l")
    done < "$2"
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

# _zb_design_line_paths_v <array> <line> — the paths a line names. A markdown
# link's target is a word of its own.
_zb_design_line_paths_v() {
    local -n _dlp="$1"; local _dlp_w _dlp_p
    local -a _dlp_ws=()
    _dlp=()
    _dlp_w="${2//](/ }"
    read -ra _dlp_ws <<< "${_dlp_w//,/ }"
    for _dlp_w in ${_dlp_ws[@]+"${_dlp_ws[@]}"}; do
        _zb_design_path_v _dlp_p "$_dlp_w"
        [[ -n "$_dlp_p" ]] && _dlp+=("$_dlp_p")
    done
    return 0
}

# zb_design_named_v <steps_array> <words_assoc> <design_md> — every path the
# design names: each step's ("<step number><TAB><path>", from its description
# and its areas), and every path anywhere in design.md and in the
# design-steps.json beside it (<words_assoc>, which must be an associative
# array: rc 2 otherwise, nothing written). Sets _ZB_DESIGN_STEP_COUNT, the
# number of steps (0: no steps block).
zb_design_named_v() {
    local -n _dqs="$1" _dqw="$2"
    # An empty array reads as unset under set -u, so its kind is read without it.
    local _dq_o="$-" _dq_k
    set +u; _dq_k="${_dqw@a}"; [[ "$_dq_o" == *u* ]] && set -u
    [[ "$_dq_k" == *A* ]] || return 2
    local _dq_l _dq_p _dq_n=0 _dq_s _dq_j=""
    local -a _dq_lines=() _dq_ps=()
    _dqs=(); _dqw=(); _ZB_DESIGN_STEP_COUNT=0
    [[ -f "${3:-}" ]] || return 0
    zb_design_step_lines_v _dq_lines "$3"
    _ZB_DESIGN_STEP_COUNT=${#_dq_lines[@]}
    for _dq_s in ${_dq_lines[@]+"${_dq_lines[@]}"}; do
        _dq_n=$(( _dq_n + 1 ))
        _zb_design_line_paths_v _dq_ps "$_dq_s"
        for _dq_p in ${_dq_ps[@]+"${_dq_ps[@]}"}; do _dqs+=("$_dq_n"$'\t'"$_dq_p"); done
    done
    while IFS= read -r _dq_l || [[ -n "$_dq_l" ]]; do
        _zb_design_line_paths_v _dq_ps "${_dq_l%$'\r'}"
        for _dq_p in ${_dq_ps[@]+"${_dq_ps[@]}"}; do _dqw["$_dq_p"]=1; done
    done < "$3"
    if [[ -s "${3%/*}/design-steps.json" ]]; then
        IFS= read -r -d '' _dq_j < "${3%/*}/design-steps.json" || true
        _zb_design_line_paths_v _dq_ps "${_dq_j//[\"\{\}\[\]]/ }"
        for _dq_p in ${_dq_ps[@]+"${_dq_ps[@]}"}; do _dqw["$_dq_p"]=1; done
    fi
    return 0
}

# _zb_design_path_names <file> <path> — rc 0 when <path>, as the design names
# it, is <file>: the same path or a path suffix of it on `/` boundaries (so a
# bare file name names every changed file of that name); a folder holding it;
# or a pattern matching it whose part before the first wildcard holds a name
# (so *, ** and *.sh match nothing).
_zb_design_path_names() {
    local _pf="${1#./}" _pp="$2" _pre
    if [[ "$_pp" == *[*?]* ]]; then
        _pre="${_pp%%[*?]*}"
        [[ -n "${_pre//[.\/]/}" ]] || return 1
        # shellcheck disable=SC2053  # the path is a pattern
        [[ "$_pf" == $_pp || "$_pf" == */$_pp ]]; return
    fi
    [[ "$_pf" == "$_pp" || "$_pf" == */"$_pp" ]] && return 0
    [[ "$_pp" == */* && -n "${_pp//\//}" && "$_pf" == "${_pp%/}/"* ]]
}

# zb_design_names_v <var> <file> <steps_array> <words_assoc> — "step:<n>" when
# step <n> names <file> (the first that does), "named" when only the rest of
# the design does, empty when it names it nowhere.
zb_design_names_v() {
    local -n _dnv="$1"; local _dn_f="$2" _dn_e _dn_w
    local -n _dn_s="$3" _dn_ws="$4"
    _dnv=""
    for _dn_e in ${_dn_s[@]+"${_dn_s[@]}"}; do
        _zb_design_path_names "$_dn_f" "${_dn_e#*$'\t'}" && { _dnv="step:${_dn_e%%$'\t'*}"; return 0; }
    done
    for _dn_w in "${!_dn_ws[@]}"; do
        _zb_design_path_names "$_dn_f" "$_dn_w" && { _dnv=named; return 0; }
    done
    return 0
}
