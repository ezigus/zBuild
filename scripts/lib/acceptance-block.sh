#!/usr/bin/env bash
# Acceptance-block extractor — parses the ```acceptance fenced block from a
# design.md artifact and emits structured output for test_assessment consumption.
# See ADR-031 for block format specification.
#
# This file is source-only (a pure function, never executed directly), so it
# deliberately does NOT `set -euo pipefail` at top level: doing so mutates the
# shell options of any caller that sources it (e.g. plugins/agent/design),
# altering their control flow. This matches the no-side-effect-on-source
# convention of the sibling core/ and scripts/lib/ libraries. The function
# below is self-contained (guarded parameter expansions + explicit returns).
#
# #2525: split, so no file is over 500 lines — acceptance-run.sh,
# acceptance-testfiles.sh and acceptance-judge.sh, sourced at the end.
#
# Every `source` here records a failed load in _ZBUILD_CONTRACT_LOAD_ERRORS
# rather than swallowing it; the gates fail on a non-empty list (#1752).

[[ -n "${_ACCEPTANCE_BLOCK_LOADED:-}" ]] && return 0
_ACCEPTANCE_BLOCK_LOADED=1

# A SPEC's id (#2462, ADR-069 §1): its stage's two-letter prefix and a code of
# 3 or 4 capital letters or digits that describes it, starting with a letter, a
# dash, and a number — DSFSTG-1 (#2482). The old `SPEC-<n>` and the ids from
# before the prefix (FSTG-1) are ids of this shape, so earlier issues' ids and
# tags still read. Every reader matches ids with this one pattern. No interval:
# awk reads it too, and mawk does not read every interval.
_ACCEPTANCE_ID_ERE='[A-Z][A-Z0-9][A-Z0-9][A-Z0-9]?[A-Z0-9]?[A-Z0-9]?-[0-9]+'
# One requirement line: `<id>[<tag>]:`. The tag may hold hyphens, so
# `[no-code]` is a tag (#2304, ADR-069 §1) — it used to be `[a-z]+`, and a
# `SPEC-2[no-code]:` line was silently dropped from every list. Groups:
# 1 = the id, 3 = the tag (empty when the line has none).
_ACCEPTANCE_SPEC_RE="^(${_ACCEPTANCE_ID_ERE})(\\[([a-z-]+)\\])?:"
# #2467 (ADR-073 §1): a part of the SPEC above it, on its own line — Given,
# When, Then, And (continues the Given, Then or Cleanup above it) or Cleanup.
# Group 2 = the part, 3 = its words.
_ACCEPTANCE_PART_RE='^(-[[:space:]]+)?(Given|When|Then|And|Cleanup)[[:space:]]*:[[:space:]]*(.*)$'

# The shared timeout helper (#1752), loaded as a same-directory
# `source "$DIR/<file>.sh"` line so _runner_contract_lib_closure lists it too.
_ACCEPTANCE_BLOCK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
# shellcheck source=./timeout-cmd.sh
source "$_ACCEPTANCE_BLOCK_DIR/timeout-cmd.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" timeout-cmd.sh"
# The repository's test folders, where a SPEC's test is found by its tag (#2508).
# shellcheck source=./test-paths.sh
source "$_ACCEPTANCE_BLOCK_DIR/test-paths.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" test-paths.sh"

# #2010: zbuild_engine_tmpdir names where engine code writes temp files (the
# run memo, #2110). Lazy-sourced, same pattern acceptance-reachability.sh uses:
# this file is sourced from several entry points and cannot assume helpers.sh
# arrived first. helpers.sh sources only compat.sh, so there is no cycle.
if ! declare -F zbuild_engine_tmpdir >/dev/null 2>&1; then
    # shellcheck source=./helpers.sh
    source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/helpers.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" helpers.sh"
fi

# extract_acceptance_block <design_md>
# Parses the ```acceptance fenced block from the given file and prints one line
# per entry — a SPEC (its parts joined to it), a REMOVED line — in order.
# Returns 0 when the block is found, 1 when there is none (empty stdout).
# #2508 (ADR-069 §11): design names no files. An old design's TESTFILES list is
# skipped, never read: its `<id>: <path>` lines would otherwise read as SPECs.
extract_acceptance_block() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 1

    local in_block=0
    local in_testfiles=0
    local found_block=0
    local -a specs=()

    while IFS= read -r line; do
        if [[ "$line" == '```acceptance' ]]; then
            in_block=1
            found_block=1
            continue
        fi
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then
            in_block=0
            break
        fi
        if [[ $in_block -eq 1 ]]; then
            if [[ "$line" == 'TESTFILES:' ]]; then
                in_testfiles=1
                continue
            fi
            # #2460: a line that carries on from the one before it is part of
            # it — a SPEC's words wrapped onto the next line. Every line is
            # trimmed; none keeps its indent.
            local _t="${line%$'\r'}"; _t="${_t#"${_t%%[![:space:]]*}"}"; _t="${_t%"${_t##*[![:space:]]}"}"
            if [[ $in_testfiles -eq 1 ]]; then
                # An old design's list ends at WIRING: or the fence.
                [[ "$_t" == 'WIRING:'* ]] && in_testfiles=0
            elif [[ "$_t" == SPEC:* || "$_t" == REMOVED:* || "$_t" =~ $_ACCEPTANCE_SPEC_RE ]]; then
                # #2462: a REMOVED line is its own entry — never part of the SPEC
                # before it — and its own wrapped words carry on to it.
                specs+=("$_t")
            elif [[ "$_t" =~ $_ACCEPTANCE_PART_RE ]]; then
                # #2467 (ADR-073 §1): a part of the SPEC above it, kept apart
                # from its words by a unit separator, so the SPEC stays one
                # entry. A part with no SPEC above it is an entry of its own,
                # for design's checks to refuse.
                if [[ ${#specs[@]} -gt 0 ]]; then specs[-1]+=$'\x1f'"${BASH_REMATCH[2]}: ${BASH_REMATCH[3]}"
                else specs+=("${BASH_REMATCH[2]}: ${BASH_REMATCH[3]}"); fi
            elif [[ -n "$_t" && ${#specs[@]} -gt 0 && ! "$_t" =~ ^[A-Z][A-Z_]*: ]]; then
                specs[-1]+=" $_t"
            fi
        fi
    done < "$design_md"

    if [[ $found_block -eq 0 ]]; then
        return 1
    fi

    for spec in "${specs[@]+"${specs[@]}"}"; do
        printf '%s\n' "$spec"
    done
    return 0
}

# acceptance_spec_tag <spec_id> — the tag an assertion carries for a SPEC: the
# id alone, [<id>] (#2520, ADR-069 §11). The issue number it once carried
# (#1845: two issues' [SPEC-3] in one shared test collided) is not needed now a
# SPEC's tests are found only in files the branch wrote (#2517) and a new id is
# numbered past every one the repository's tests use.
acceptance_spec_tag() {
    printf '[%s]' "${1:-}"
}

# acceptance_spec_tags_v <array> <spec_id> — every tag that marks a SPEC's test:
# [<id>], and under an issue this issue's old [#<issue>/<id>], still read so
# tests written before #2520 are found (another issue's is not).
acceptance_spec_tags_v() {
    local -n _ast="$1"; local issue="${ZBUILD_ISSUE:-}"
    _ast=("[${2:-}]")
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] && _ast+=("[#$issue/${2:-}]")
    return 0
}

# acceptance_list_spec_ids <design_md>  (ADR-036 / #922)
# Prints each STABLE SPEC id (e.g. "SPEC-1", "SPEC-2") from the ```acceptance
# block, one per line, in declaration order. Only `SPEC-<n>:` lines carry an
# id; bare legacy `SPEC:` lines are intentionally ignored (they have no id to
# map to a [SPEC-n]-tagged assertion). Returns 0 when ≥1 id is found, else 1.
acceptance_list_spec_ids() {
    local design_md="${1:-}"
    local block_output line ids_found=0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 1
    [[ -z "$block_output" ]] && return 1
    while IFS= read -r line; do
        if [[ "$line" =~ $_ACCEPTANCE_SPEC_RE ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            ids_found=1
        fi
    done <<< "$block_output"
    [[ $ids_found -eq 1 ]]
}

# _acceptance_spec_line <block_output> <spec_id>  (#2304, ADR-069 §1)
# Finds the requirement line for <spec_id> in an extracted block and sets, with
# no subshell (so reading a requirement costs no extra fork):
#   _ACC_SPEC_TAG    the tag, or empty
#   _ACC_SPEC_STATUS code | no-code | doc | done | unknown:<tag> | "" (no tag). The
#                    old tags are still read: [change] is code, and [guard] is
#                    done (the design-gate rejects [guard], so a new design
#                    never carries it; an old one still reads sensibly).
#   _ACC_SPEC_REST   everything after the colon, leading space trimmed
#   _ACC_SPEC_TEXT   what it requires: REST, stopping before ` covers: ` and,
#                    when the requirement is done, before ` evidence: ` (neither
#                    is part of the requirement)
#   _ACC_SPEC_COVERS the issue requirement ids after ` covers: ` (R-1 R-3), up
#                    to any ` evidence: ` — space separated (#2306, ADR-070 §3)
#   _ACC_SPEC_PARTS  its Given/When/Then/And/Cleanup lines as written, each
#                    "<Part>: <words>", joined by a unit separator (#2467)
# Returns 1 when the block has no such line.
_acceptance_spec_line() {
    local _block="${1:-}" _sid="${2:-}" _l
    _ACC_SPEC_TAG="" _ACC_SPEC_STATUS="" _ACC_SPEC_REST="" _ACC_SPEC_TEXT="" _ACC_SPEC_COVERS="" _ACC_SPEC_PARTS=""
    [[ -n "$_block" && -n "$_sid" ]] || return 1
    while IFS= read -r _l; do
        if [[ "$_l" =~ $_ACCEPTANCE_SPEC_RE && "${BASH_REMATCH[1]}" == "$_sid" ]]; then
            # #2467: its parts follow its first line, each after a unit separator.
            if [[ "$_l" == *$'\x1f'* ]]; then _ACC_SPEC_PARTS="${_l#*$'\x1f'}"; _l="${_l%%$'\x1f'*}"; fi
            _ACC_SPEC_TAG="${BASH_REMATCH[3]}"
            _ACC_SPEC_REST="${_l#*:}"
            _ACC_SPEC_REST="${_ACC_SPEC_REST#"${_ACC_SPEC_REST%%[![:space:]]*}"}"
            _ACC_SPEC_TEXT="${_ACC_SPEC_REST%% covers: *}"
            if [[ "$_ACC_SPEC_REST" == *" covers: "* ]]; then
                _ACC_SPEC_COVERS="${_ACC_SPEC_REST#* covers: }"
                _ACC_SPEC_COVERS="${_ACC_SPEC_COVERS%% evidence: *}"
            fi
            case "$_ACC_SPEC_TAG" in
                "")          _ACC_SPEC_STATUS="" ;;
                code|change) _ACC_SPEC_STATUS="code" ;;
                no-code)     _ACC_SPEC_STATUS="no-code" ;;
                doc)         _ACC_SPEC_STATUS="doc" ;;
                done|guard)  _ACC_SPEC_STATUS="done"
                             _ACC_SPEC_TEXT="${_ACC_SPEC_TEXT%% evidence: *}" ;;
                *)           _ACC_SPEC_STATUS="unknown:$_ACC_SPEC_TAG" ;;
            esac
            return 0
        fi
    done <<< "$_block"
    return 1
}

# acceptance_parts_v <array_var> <parts> [problems_var] [written_var] — a SPEC's
# parts (_ACC_SPEC_PARTS) as "<label><TAB><words>", in order (#2467, ADR-073
# §1). The labels tell the parts apart inside the engine: "Given 1", "When",
# "Then 2", "Cleanup 1". And continues the Given, Then or Cleanup above it and
# takes its next number. With [problems_var], each thing wrong with them:
# NO_WHEN, MANY_WHEN, NO_THEN, AND_AFTER_WHEN, AND_FIRST, and "EMPTY <label>"
# for a part with no words. With [written_var], each part's word as design wrote
# it — Given, When, Then, And, Cleanup — which is all a model is ever shown
# (#2470).
acceptance_parts_v() {
    local -n _apv="$1"; local _apv_raw="${2:-}" _apv_pl="${3:-}" _apv_wl="${4:-}"
    local -a _apv_wr=()
    local _apv_g=0 _apv_w=0 _apv_t=0 _apv_c=0 _apv_last="" _apv_k _apv_x _apv_lab
    local -a _apv_pr=()
    _apv=()
    # read, not word splitting: a part's words may hold a * or a ?.
    local -a _apv_items=()
    [[ -n "$_apv_raw" ]] && IFS=$'\x1f' read -r -d '' -a _apv_items <<< "$_apv_raw"
    [[ ${#_apv_items[@]} -gt 0 ]] && _apv_items[-1]="${_apv_items[-1]%$'\n'}"
    for _apv_x in ${_apv_items[@]+"${_apv_items[@]}"}; do
        _apv_k="${_apv_x%%:*}"; _apv_x="${_apv_x#*:}"; _apv_x="${_apv_x# }"
        _apv_wr+=("$_apv_k")
        if [[ "$_apv_k" == And ]]; then
            case "$_apv_last" in
                "")   _apv_pr+=(AND_FIRST); _apv_k=Then ;;
                When) _apv_pr+=(AND_AFTER_WHEN); _apv_k=When ;;
                *)    _apv_k="$_apv_last" ;;
            esac
        fi
        case "$_apv_k" in
            Given)   _apv_g=$((_apv_g + 1)); _apv_lab="Given $_apv_g" ;;
            When)    _apv_w=$((_apv_w + 1)); _apv_lab="When"; (( _apv_w > 1 )) && _apv_lab="When $_apv_w" ;;
            Then)    _apv_t=$((_apv_t + 1)); _apv_lab="Then $_apv_t" ;;
            Cleanup) _apv_c=$((_apv_c + 1)); _apv_lab="Cleanup $_apv_c" ;;
        esac
        _apv_last="$_apv_k"
        [[ -n "${_apv_x//[[:space:]]/}" ]] || _apv_pr+=("EMPTY $_apv_lab")
        _apv+=("$_apv_lab"$'\t'"$_apv_x")
    done
    if [[ -n "$_apv_wl" ]]; then
        local -n _apv_w2="$_apv_wl"
        _apv_w2=(${_apv_wr[@]+"${_apv_wr[@]}"})
    fi
    if [[ -n "$_apv_pl" ]]; then
        local -n _apv_p="$_apv_pl"
        (( _apv_w == 0 )) && _apv_pr+=(NO_WHEN)
        (( _apv_w > 1 )) && [[ " ${_apv_pr[*]-} " != *" AND_AFTER_WHEN "* ]] && _apv_pr+=(MANY_WHEN)
        (( _apv_t == 0 )) && _apv_pr+=(NO_THEN)
        _apv_p=(${_apv_pr[@]+"${_apv_pr[@]}"})
    fi
    return 0
}

# acceptance_spec_parts_v <array_var> <block_output> <spec_id> — the SPEC's
# parts, as acceptance_parts_v gives them; none for a SPEC written on one line.
acceptance_spec_parts_v() {
    local -n _aspv="$1"
    _aspv=()
    _acceptance_spec_line "$2" "$3" || return 0
    acceptance_parts_v _aspv "$_ACC_SPEC_PARTS"
}

# acceptance_parts_shown_v <array_var> <parts> — a SPEC's parts as a model is
# shown them, "<word><TAB><words>", the word as design wrote it: Given, When,
# Then, And, Cleanup — never a number (#2470, ADR-073 §2).
acceptance_parts_shown_v() {
    local -n _aps="$1"; local -a _aps_p=() _aps_w=(); local _aps_i
    _aps=()
    acceptance_parts_v _aps_p "${2:-}" "" _aps_w
    for _aps_i in "${!_aps_p[@]}"; do _aps+=("${_aps_w[_aps_i]}"$'\t'"${_aps_p[_aps_i]#*$'\t'}"); done
}

# acceptance_spec_render_v <var> <block_output> <spec_id> [indent] — the SPEC's
# words and, under them, each of its parts by the word design wrote: how a SPEC
# is shown to a model (#2467, #2470, ADR-073 §2).
acceptance_spec_render_v() {
    local -n _asr="$1"; local _asr_i="${4-  }" _asr_x
    _asr=""
    _acceptance_spec_line "$2" "$3" || return 0
    _asr="$_ACC_SPEC_TEXT"
    local -a _asr_p=()
    acceptance_parts_shown_v _asr_p "$_ACC_SPEC_PARTS"
    for _asr_x in ${_asr_p[@]+"${_asr_p[@]}"}; do _asr+=$'\n'"${_asr_i}${_asr_x%%$'\t'*}: ${_asr_x#*$'\t'}"; done
    return 0
}

# acceptance_block_render_v <var> <block_output> — the extracted block as a
# model reads it: each SPEC's parts on their own lines, as written, under it.
acceptance_block_render_v() {
    local -n _abr="$1"; local _abr_l _abr_x
    _abr=""
    while IFS= read -r _abr_l; do
        if [[ "$_abr_l" == *$'\x1f'* ]]; then
            local -a _abr_p=()
            acceptance_parts_shown_v _abr_p "${_abr_l#*$'\x1f'}"
            _abr+="${_abr_l%%$'\x1f'*}"$'\n'
            for _abr_x in ${_abr_p[@]+"${_abr_p[@]}"}; do _abr+="  ${_abr_x%%$'\t'*}: ${_abr_x#*$'\t'}"$'\n'; done
        else
            _abr+="$_abr_l"$'\n'
        fi
    done <<< "$2"
    _abr="${_abr%$'\n'}"
}

# acceptance_spec_status <design_md> <spec_id>  (#2304, ADR-069 §1)
# Echoes the requirement's status: code, no-code, doc, done, unknown:<tag>, or an
# empty line when it carries no tag or the id is absent.
acceptance_spec_status() {
    local design_md="${1:-}" spec_id="${2:-}" block_output
    [[ -n "$design_md" && -n "$spec_id" && -f "$design_md" ]] || { printf '\n'; return 0; }
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || { printf '\n'; return 0; }
    _acceptance_spec_line "$block_output" "$spec_id" || { printf '\n'; return 0; }
    printf '%s\n' "$_ACC_SPEC_STATUS"
}

# acceptance_spec_evidence <design_md> <spec_id>  (#2304, ADR-069 §1)
# Echoes the evidence an "already done" requirement names — the items after
# ` evidence: ` on its line, one per line: `<file> | <one line>` (#2519), the
# old `file:"exact text"`, or a test file (#2462; the old `file:line` still
# reads, and design's checks refuse it). Empty for any other status, and when
# none is named.
acceptance_spec_evidence() {
    local design_md="${1:-}" spec_id="${2:-}" block_output
    [[ -n "$design_md" && -n "$spec_id" && -f "$design_md" ]] || return 0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    _acceptance_spec_line "$block_output" "$spec_id" || return 0
    [[ "$_ACC_SPEC_STATUS" == "done" && "$_ACC_SPEC_REST" == *" evidence: "* ]] || return 0
    local _ev="${_ACC_SPEC_REST#* evidence: }"
    local -a _items=()
    # %% (from the FIRST " covers: "), not %: evidence ends where covers begins.
    _acceptance_evidence_items_v _items "${_ev%% covers: *}"
    [[ ${#_items[@]} -gt 0 ]] && printf '%s\n' "${_items[@]}"
    return 0
}

# _acceptance_evidence_items_v <array> <evidence> — the items of a [done]
# requirement's evidence, split on spaces except inside a quoted text (#2462).
# `<file> | <one line>` is one item, the line running to the end (#2519).
_acceptance_evidence_items_v() {
    local -n _aei="$1"; local _s="$2" _re='^[[:space:]]*([^[:space:]"]+:"[^"]*"|[^[:space:]]+)(.*)$'
    _aei=()
    if [[ "$_s" =~ ^[[:space:]]*([^[:space:]|]+[[:space:]]+\|[[:space:]]+.*[^[:space:]])[[:space:]]*$ ]]; then
        _aei=("${BASH_REMATCH[1]}"); return 0
    fi
    while [[ "$_s" =~ $_re ]]; do _aei+=("${BASH_REMATCH[1]}"); _s="${BASH_REMATCH[2]}"; done
    return 0
}

# acceptance_evidence_split <item> <path_var> <text_var> <line_var> — one
# evidence item's parts: `<file> | <line>` and the old `file:"text"` set path
# and text, the old `file:N` sets path and line, a bare path sets path alone.
acceptance_evidence_split() {
    local -n _aesp="$2" _aest="$3" _aesl="$4"
    local _it="$1" _rt='^([^"]+):"(.*)"$' _rl='^(.+):([0-9]+)$' _rb='^([^[:space:]|]+)[[:space:]]+\|[[:space:]]+(.*)$'
    _aesp="$_it" _aest="" _aesl=""
    if [[ "$_it" =~ $_rb ]]; then _aesp="${BASH_REMATCH[1]}"; _aest="${BASH_REMATCH[2]}"
    elif [[ "$_it" =~ $_rt ]]; then _aesp="${BASH_REMATCH[1]}"; _aest="${BASH_REMATCH[2]}"
    elif [[ "$_it" =~ $_rl ]]; then _aesp="${BASH_REMATCH[1]}"; _aesl="${BASH_REMATCH[2]}"; fi
    return 0
}

# acceptance_list_removed_ids <design_md>  (#2462, ADR-069 §1)
# Each `REMOVED: <id> — <why>` line of the acceptance block, as "<id><TAB><why>".
acceptance_list_removed_ids() {
    local design_md="${1:-}" blk l re
    re="^REMOVED:[[:space:]]*(${_ACCEPTANCE_ID_ERE})[[:space:]]*(—|–|-|:)?[[:space:]]*(.*)$"
    blk="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    while IFS= read -r l; do
        [[ "$l" =~ $re ]] && printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]%%$'\x1f'*}"
    done <<< "$blk"
    return 0
}

# acceptance_spec_covers <design_md> <spec_id>  (#2306, ADR-070 §3)
# Echoes the issue requirement ids the SPEC says it covers — the items after
# ` covers: ` on its line, up to any ` evidence: ` — one per line. Empty when it
# names none.
acceptance_spec_covers() {
    local design_md="${1:-}" spec_id="${2:-}" block_output
    [[ -n "$design_md" && -n "$spec_id" && -f "$design_md" ]] || return 0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    _acceptance_spec_line "$block_output" "$spec_id" || return 0
    local -a _ids=()
    read -ra _ids <<< "${_ACC_SPEC_COVERS//,/ }"
    [[ ${#_ids[@]} -gt 0 ]] && printf '%s\n' "${_ids[@]}"
    return 0
}

# acceptance_requirements_list <requirements.json>  (#2306, ADR-070 §4)
# The issue's requirements as every stage is shown them: one `- <id>: <text>`
# line each, in order. Empty when the file is absent or unreadable (a goal run).
acceptance_requirements_list() {
    local f="${1:-}"
    [[ -n "$f" && -s "$f" ]] || return 0
    jq -r '.requirements[]? | "- \(.id): \(.text)"' "$f" 2>/dev/null || true
}

# acceptance_spec_text <design_md> <spec_id>  (#1978)
# Echoes what the SPEC REQUIRES — the prose after `SPEC-n[tag]:` — with no id,
# no tag, and (#2304) no evidence. Empty when the id is absent or the block is
# missing.
acceptance_spec_text() {
    local design_md="${1:-}" spec_id="${2:-}" block_output
    [[ -n "$design_md" && -n "$spec_id" && -f "$design_md" ]] || return 0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    [[ -z "$block_output" ]] && return 0
    _acceptance_spec_line "$block_output" "$spec_id" || return 0
    printf '%s\n' "$_ACC_SPEC_TEXT"
    return 0
}

# acceptance_list_wiring <design_md>  (ADR-036 Level-3 / #956)
# Prints the WIRING targets declared in the ```acceptance block, one per line.
# The special token "none" is printed as-is when WIRING: none is declared
# (pure-utility exemption). Path-traversal guard applied (same as testfiles).
# Returns 0 when a WIRING: section is present (even if "none"), 1 when absent.
acceptance_list_wiring() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 1

    local in_block=0 in_wiring=0 found_wiring=0

    while IFS= read -r line; do
        line="${line%$'\r'}"  # tolerate CRLF on ALL lines (sentinels + paths)
        if [[ "$line" == '```acceptance' ]]; then
            in_block=1
            continue
        fi
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then
            break
        fi
        if [[ $in_block -eq 1 ]]; then
            # Stop wiring collection when a new recognized sentinel is hit
            # #2462: a SPEC or binding line, whatever its id, ends the list.
            [[ $in_wiring -eq 1 && "${line#"${line%%[![:space:]]*}"}" =~ ^${_ACCEPTANCE_ID_ERE}(\[[a-z-]+\])?: ]] && in_wiring=0
            if [[ $in_wiring -eq 1 ]]; then
                case "$line" in
                    TESTFILES:|SPEC:*|REMOVED:*) in_wiring=0 ;;
                    '') continue ;;
                    *)
                        [[ -z "$line" ]] && continue
                        [[ "$line" == /* || "/$line/" == *"/../"* ]] && continue
                        printf '%s\n' "$line"
                        continue
                        ;;
                esac
            fi
            if [[ "$line" == 'WIRING: none' ]]; then
                printf 'none\n'
                found_wiring=1
                in_wiring=0
            elif [[ "$line" == 'WIRING:' ]]; then
                found_wiring=1
                in_wiring=1
            elif [[ "$line" == 'WIRING: '* ]]; then
                # inline single path (not "none")
                local wpath="${line#WIRING: }"
                wpath="${wpath%$'\r'}"
                [[ -z "$wpath" || "$wpath" == /* || "/$wpath/" == *"/../"* ]] || printf '%s\n' "$wpath"
                found_wiring=1
                in_wiring=0
            fi
        fi
    done < "$design_md"

    [[ $found_wiring -eq 1 ]] && return 0
    return 1
}

# #2525: the rest of the acceptance-block readers, split by what each does so
# no file passes 500 lines. Same-directory lines, so _runner_contract_lib_closure
# lists them too.
# shellcheck source=./acceptance-run.sh
source "$_ACCEPTANCE_BLOCK_DIR/acceptance-run.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" acceptance-run.sh"
# shellcheck source=./acceptance-testfiles.sh
source "$_ACCEPTANCE_BLOCK_DIR/acceptance-testfiles.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" acceptance-testfiles.sh"
# shellcheck source=./acceptance-judge.sh
source "$_ACCEPTANCE_BLOCK_DIR/acceptance-judge.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" acceptance-judge.sh"
