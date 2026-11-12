#!/usr/bin/env bash
# scripts/lib/acceptance-testfiles.sh — the test files that hold each SPEC's tag (#2508), and
# the checks this change makes wrong (#2243).
# Split from acceptance-block.sh (#2525), which sources it: load that file, not
# this one.
#
# Sourced library: no set -euo pipefail.

# acceptance_list_supersedes <design_md>  (#2243)
# The existing checks this change makes wrong, from design.md's ```supersedes
# block — a fact about the change, stated by design; updating them to the new
# behaviour is test-author's (#1842: nobody could, so build evaded one). One line
# per check:  <repo-relative-path> <tag>: <why>
# Prints "<path>\t<tag>\t<why>" per valid line. Absolute and ../ paths are
# refused. No block → nothing.
acceptance_list_supersedes() {
    local design_md="${1:-}" line in_block=0 path rest tag why
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" == '```supersedes' ]]; then in_block=1; continue; fi
        # Every block counts, not only the first (review #2247).
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then in_block=0; continue; fi
        [[ $in_block -eq 1 && -n "$line" ]] || continue
        path="${line%% *}"; rest="${line#* }"
        [[ "$path" == /* || "/$path/" == *"/../"* || "$rest" == "$line" ]] && continue
        tag="${rest%%:*}"; why="${rest#*:}"; why="${why# }"
        [[ "$tag" == "["*"]" ]] || continue
        printf '%s\t%s\t%s\n' "$path" "$tag" "$why"
    done < "$design_md"
}

# acceptance_spec_files_v <map_var> <design_md> [repo_root]  (#2508, ADR-069 §11)
# Each SPEC's test files, found by its tag: map[<id>] = the files in the
# repository's test folders (scripts/lib/test-paths.sh) that this branch added
# or changed (#2517) and that hold the tag
# acceptance_spec_tag builds for it, space separated, sorted. Design names no
# files; test-author writes the tests wherever they belong, committed or not.
# Two forks for every SPEC at once: git lists the files, one grep reads them.
acceptance_spec_files_v() {
    local -n _asf="$1"; local design_md="${2:-}" root="${3:-${ZBUILD_REPO_ROOT:-$PWD}}"
    _asf=()
    [[ -n "$design_md" && -f "$design_md" && -d "$root" ]] || return 0
    local blk l tag sid
    local -A _by_tag=()
    local -a _tgs=()
    blk="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    while IFS= read -r l; do
        [[ "$l" =~ $_ACCEPTANCE_SPEC_RE ]] || continue
        sid="${BASH_REMATCH[1]}"
        acceptance_spec_tags_v _tgs "$sid"
        for tag in "${_tgs[@]}"; do _by_tag[$tag]="$sid"; done
    done <<< "$blk"
    [[ ${#_by_tag[@]} -gt 0 ]] || return 0
    local f
    local -a files=() pats=()
    zb_test_folder_branch_files_v files "$root"
    [[ ${#files[@]} -gt 0 ]] || return 0
    for tag in "${!_by_tag[@]}"; do pats+=(-e "$tag"); done
    local id cur
    # -o prints each tag found, after its file and a NUL (--null).
    while IFS= read -r -d '' f && IFS= read -r tag; do
        id="${_by_tag[$tag]:-}"
        [[ -n "$id" ]] || continue
        cur=" ${_asf[$id]:-} "
        [[ "$cur" == *" $f "* ]] || _asf[$id]="${_asf[$id]:+${_asf[$id]} }$f"
    done < <(cd "$root" && grep -oHIF --null "${pats[@]}" -- "${files[@]}" 2>/dev/null)
    for id in "${!_asf[@]}"; do _acceptance_sort_words_v "_asf[$id]" "${_asf[$id]}"; done
    return 0
}

# _acceptance_sort_words_v <var> <words> — the words, sorted (byte order), in
# the shell: a SPEC has a few test files, not enough to pay for a sort fork.
_acceptance_sort_words_v() {
    local -n _asw="$1"; local -a _in=() _out=(); local w i
    read -ra _in <<< "$2"
    for w in ${_in[@]+"${_in[@]}"}; do
        i=${#_out[@]}
        while (( i > 0 )) && [[ "${_out[i-1]}" > "$w" ]]; do _out[i]="${_out[i-1]}"; i=$((i - 1)); done
        _out[i]="$w"
    done
    _asw="${_out[*]-}"
}

# acceptance_list_testfiles <design_md> [repo_root] — every SPEC's test files,
# found by tag (acceptance_spec_files_v), each once, sorted, one per line.
acceptance_list_testfiles() {
    local -A _alt=(); local _alt_all="" _alt_id _alt_f
    acceptance_spec_files_v _alt "${1:-}" "${2:-}"
    for _alt_id in "${!_alt[@]}"; do
        for _alt_f in ${_alt[$_alt_id]}; do
            [[ " $_alt_all " == *" $_alt_f "* ]] || _alt_all+="${_alt_all:+ }$_alt_f"
        done
    done
    _acceptance_sort_words_v _alt_all "$_alt_all"
    local -a _alt_w=(); read -ra _alt_w <<< "$_alt_all"
    [[ ${#_alt_w[@]} -gt 0 ]] && printf '%s\n' "${_alt_w[@]}"
    return 0
}

# acceptance_spec_desc <design_md> <spec_id>  (#1684)
# Echoes the description text from the SPEC-n line in the acceptance block —
# the text after the colon on the matching `SPEC-<id>[classifier]: <text>` line.
# Truncates to 100 characters with '…' when longer — long enough that the
# clause distinguishing one SPEC from another survives, which is the point of
# showing it. Returns empty string (not an error) when the SPEC id is not found.
acceptance_spec_desc() {
    local design_md="${1:-}" spec_id="${2:-}"
    [[ -z "$design_md" || -z "$spec_id" || ! -f "$design_md" ]] && return 0
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    _acceptance_spec_line "$block_output" "$spec_id" || return 0
    local text="$_ACC_SPEC_TEXT"
    if [[ ${#text} -gt 100 ]]; then
        printf '%s…\n' "${text:0:100}"
    else
        printf '%s\n' "$text"
    fi
    return 0
}

# acceptance_list_testfiles_for_spec <design_md> <spec_id> [repo_root] — the
# SPEC's test files, found by its tag (acceptance_spec_files_v), one per line.
acceptance_list_testfiles_for_spec() {
    local -A _altf=()
    [[ -n "${2:-}" ]] || return 0
    acceptance_spec_files_v _altf "${1:-}" "${3:-}"
    local -a _altf_w=(); read -ra _altf_w <<< "${_altf[$2]:-}"
    [[ ${#_altf_w[@]} -gt 0 ]] && printf '%s\n' "${_altf_w[@]}"
    return 0
}
