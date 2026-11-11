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
# Size: over 500 lines, deliberately, for the reason acceptance-negctl.sh gives.
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

# acceptance_spec_tag <spec_id> — the tag an assertion carries for a SPEC.
# Under an issue: [#<issue>/SPEC-n] — SPEC numbers restart with every design, so
# a bare [SPEC-3] cannot say WHICH issue's SPEC-3 it is, and two issues sharing a
# test file collided (#1845 stripped #1328's [SPEC-1..10]). The scheme adds to
# the old one and never overlaps it: `\[SPEC-[0-9]+\]` cannot match a new tag,
# and every reader matches the exact tag it builds here. With no issue (a
# --goal run, ZBUILD_ISSUE unset or 0) it is the bare legacy [SPEC-n].
acceptance_spec_tag() {
    local sid="${1:-}" issue="${ZBUILD_ISSUE:-}"
    if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
        printf '[#%s/%s]' "$issue" "$sid"
    else
        printf '[%s]' "$sid"
    fi
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
#   _ACC_SPEC_STATUS code | no-code | done | unknown:<tag> | "" (no tag). The
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
# Echoes the requirement's status: code, no-code, done, unknown:<tag>, or an
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

# acceptance_evidence_line_v <var> <content> <text> — the number of the first
# line of <content> that holds <text>, or empty. Read by the shell, no fork.
acceptance_evidence_line_v() {
    local -n _ael="$1"; local _l _n=0
    _ael=""
    [[ -n "$3" ]] || return 0
    while IFS= read -r _l; do
        _n=$((_n + 1))
        [[ "$_l" == *"$3"* ]] && { _ael="$_n"; return 0; }
    done <<< "$2"
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

# _acceptance_build_run_cmd <template> <testfile>
# Expands a {files}-template for a single acceptance testfile.
# Prints each command token NUL-separated for safe array construction by callers.
# Returns 1 when the template contains no {files} token (misconfiguration guard).
#
# The template is whitespace-tokenized (read -ra) and the resulting array is
# exec'd DIRECTLY by callers — the testfile path never passes through a shell,
# so a filename cannot inject shell metacharacters. This is deliberate and is
# why templates are simple whitespace-separated tokens (bash {files},
# pytest {files}, jest {files}, cargo test {files}); a template embedding a
# quoted multi-word argument (e.g. python3 -c 'import sys') is NOT supported —
# honoring shell quoting would require eval, reintroducing the injection risk
# this array-exec design avoids. ZBUILD_ACCEPTANCE_RUN_CMD is operator-declared
# config (same trust model as ZBUILD_TEST_CMD_TARGETED), not untrusted input.
_acceptance_build_run_cmd() {
    local template="$1" testfile="$2"
    [[ "$template" != *'{files}'* ]] && return 1
    local -a parts
    read -ra parts <<< "$template"
    local part
    for part in "${parts[@]}"; do
        if [[ "$part" == '{files}' ]]; then
            printf '%s\0' "$testfile"
        else
            printf '%s\0' "$part"
        fi
    done
    return 0
}

# _acceptance_timeout_prefix lives in timeout-cmd.sh (#1752), loaded above —
# the one helper every timeout bound in core/, scripts/ and plugins/ uses.

# _acceptance_file_timeout <testfile_rel> <stage_bound_s>  (#2110)
# The bound for ONE run of ONE file: the stage value raised to 3x the time the
# test stage MEASURED for that file (artifacts/test-timing.log, `file <ms>
# <path>`), never lowered, clamped at the test stage's own per-file ceiling
# (ZBUILD_TEST_FILE_TIMEOUT, default 480). A flat 60s condemned a file the test
# stage had just accepted at 129s — all 18 SPECs read `timeout`, 68 minutes per
# gate pass (#1840). The timing log's paths point into a staging dir that no
# longer exists, so the match is on the repo-relative suffix. Unmeasured file
# (targeted reruns log only their subset) → stage value. ZBUILD_NEGCTL_TIMEOUT_MEASURED=0
# disables the raise. The log is the gate's declared `test_timing` input
# (ZBUILD_NEGCTL_TIMING_LOG, ADR-055 §1); this helper never rebuilds a path.
_acceptance_file_timeout() {
    local tf="$1" stage_s="$2"
    [[ "$stage_s" =~ ^[0-9]+$ ]] || stage_s=60
    [[ "${ZBUILD_NEGCTL_TIMEOUT_MEASURED:-1}" == "1" ]] || { printf '%s' "$stage_s"; return 0; }
    local log="${ZBUILD_NEGCTL_TIMING_LOG:-}"
    [[ -n "$tf" && -n "$log" && -f "$log" ]] || { printf '%s' "$stage_s"; return 0; }
    local ceiling="${ZBUILD_TEST_FILE_TIMEOUT:-480}"
    [[ "$ceiling" =~ ^[0-9]+$ && "$ceiling" -gt 0 ]] || ceiling=480
    local kind ms path best_ms=0
    while read -r kind ms path; do
        [[ "$kind" == "file" && "$ms" =~ ^[0-9]+$ ]] || continue
        [[ "$path" == "$tf" || "$path" == */"$tf" ]] || continue
        (( ms > best_ms )) && best_ms=$ms
    done < "$log"
    local bound=$stage_s
    if (( best_ms > 0 )); then
        local measured_s=$(( (best_ms + 999) / 1000 ))
        (( measured_s * 3 > bound )) && bound=$(( measured_s * 3 ))
        (( bound > ceiling )) && bound=$ceiling
        (( bound < stage_s )) && bound=$stage_s
    fi
    printf '%s' "$bound"
}

# ─── _acceptance_run_cached <key> <logfile> <cmd...>  (#2110) ───────────────
# Memoises ONE execution of a test file per gate pass. The gate used to run the
# whole file twice PER SPEC — 19 SPECs bound to one file = 38 runs of the same
# thing, each answering every question the first pair already had. The verdict
# for a SPEC is a pure function of (rc, capture) at baseline and at HEAD, so
# every SPEC bound to the same file reads the same pair. The memo is a
# directory of files (rc + capture), not a shell array: callers run inside
# `$( )` and `< <( )`, where an array would die with the subshell.
#
# Keyed by the absolute path, which already separates a baseline worktree from
# HEAD and one reverted-target worktree from another. Scope: the directory in
# _ACCEPTANCE_RUN_CACHE_DIR — created by the check that runs first (or by the
# plugin, so negctl and reachability share HEAD runs) and removed with it.
# When the directory is unset, every call executes (pre-#2110 behaviour).
_acceptance_run_cached() {
    local key="$1" logfile="$2"; shift 2
    local dir="${_ACCEPTANCE_RUN_CACHE_DIR:-}"
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        if [[ -n "$logfile" ]]; then "$@" >>"$logfile" 2>&1 3>>"$logfile"; else "$@" >/dev/null 2>&1 3>&-; fi
        return $?
    fi
    # The key is a digest of the path, not a sanitised path: `tests/a/b.sh`
    # and `tests/a_b.sh` would otherwise share one entry, and the second file
    # would replay the first's verdict without ever running (review, #2110).
    local id; id="$(printf '%s' "$key" | cksum)"; id="${id%% *}-${#key}"
    local rcf="$dir/$id.rc" capf="$dir/$id.cap"
    local cached=""
    if [[ -f "$rcf" ]]; then
        read -r cached < "$rcf" || cached=""
    fi
    if [[ "$cached" =~ ^[0-9]+$ ]]; then
        [[ -n "$logfile" && -f "$capf" ]] && cat "$capf" >> "$logfile" 2>/dev/null
        return "$cached"
    fi
    local rc=0
    : > "$capf"
    "$@" >>"$capf" 2>&1 3>>"$capf" || rc=$?
    printf '%s\n' "$rc" > "$rcf"
    [[ -n "$logfile" ]] && cat "$capf" >> "$logfile" 2>/dev/null
    return "$rc"
}

# _acceptance_run_cache_begin — ensure a memo dir exists for this check. Sets
# _ACCEPTANCE_RUN_CACHE_OWNED=1 when this call created it (the caller removes
# it on return), 0 when it joined one the plugin already opened. A global, not
# stdout: the directory must be set in the CALLER's shell, and `$( )` would
# lose it.
_acceptance_run_cache_begin() {
    _ACCEPTANCE_RUN_CACHE_OWNED=0
    if [[ -n "${_ACCEPTANCE_RUN_CACHE_DIR:-}" && -d "$_ACCEPTANCE_RUN_CACHE_DIR" ]]; then
        return 0
    fi
    _ACCEPTANCE_RUN_CACHE_DIR="$(mktemp -d "$(zbuild_engine_tmpdir)/zb-accept-runs.XXXXXX" 2>/dev/null || true)"
    export _ACCEPTANCE_RUN_CACHE_DIR
    [[ -n "$_ACCEPTANCE_RUN_CACHE_DIR" ]] && _ACCEPTANCE_RUN_CACHE_OWNED=1
    return 0
}

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
    local blk l issue="${ZBUILD_ISSUE:-}" tag sid
    local -A _by_tag=()
    blk="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || issue=""
    while IFS= read -r l; do
        [[ "$l" =~ $_ACCEPTANCE_SPEC_RE ]] || continue
        sid="${BASH_REMATCH[1]}"
        # acceptance_spec_tag's rule, inline: one subshell per SPEC otherwise.
        if [[ -n "$issue" ]]; then tag="[#$issue/$sid]"; else tag="[$sid]"; fi
        _by_tag[$tag]="$sid"
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

# design_decisions_prose <design_md> [max_lines] — the design's DECISION PROSE:
# everything outside fenced blocks, capped (default 120 lines). Empty when absent.
# Shared by build (honours the decisions) and review-lens (judges against them,
# #1654) — one extractor, so the two cannot read a design differently.
design_decisions_prose() {
    local design_md="${1:-}" cap="${2:-120}" body
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    body="$(awk -v cap="$cap" '
        /^```/ { infence = !infence; next }
        infence { next }
        { print; emitted++ }
        emitted >= cap { exit }
    ' "$design_md" 2>/dev/null || true)"
    body="$(printf '%s\n' "$body" | sed '/./,$!d')"
    [[ -z "${body//[[:space:]]/}" ]] && return 0
    printf '%s\n' "$body"
}

# acceptance_requirements_for_judge <design_md>  (#2304, ADR-069 §7)
# The requirements as issue-acceptance reads them: each one's words and, in
# plain words, what its status means — never the raw tag. A done requirement
# also gets its evidence, a file and a piece of its text: the judge opens the
# file and reads as much of it as it needs (#2464, ADR-072 §2 — no window of
# lines). The caller cleans the text before it reaches a model.
acceptance_requirements_for_judge() {
    local design_md="${1:-}" blk l sid ev
    blk="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    while IFS= read -r l; do
        [[ "$l" =~ $_ACCEPTANCE_SPEC_RE ]] || continue
        sid="${BASH_REMATCH[1]}"
        _acceptance_spec_line "$blk" "$sid" || continue
        printf -- '- %s: %s\n' "$sid" "$_ACC_SPEC_TEXT"
        # #2467: and its parts, each on its own line.
        local -a _rfj_p=(); local _rfj_x
        acceptance_parts_shown_v _rfj_p "$_ACC_SPEC_PARTS"
        for _rfj_x in ${_rfj_p[@]+"${_rfj_p[@]}"}; do printf '  %s: %s\n' "${_rfj_x%%$'\t'*}" "${_rfj_x#*$'\t'}"; done
        case "$_ACC_SPEC_STATUS" in
            no-code) printf '  Status: needs work (no code) — nothing checked it mechanically; judge it yourself, and say whether its tests would catch it broken\n' ;;
            done)    printf '  Status: already done — design says the code already does this; check the claim\n' ;;
            *)       printf '  Status: needs work (code) — its test failed on the old code and passes now\n'; continue ;;
        esac
        [[ "$_ACC_SPEC_STATUS" == "done" && "$_ACC_SPEC_REST" == *" evidence: "* ]] || continue
        local -a _evs=(); local _evl="${_ACC_SPEC_REST#* evidence: }"
        _acceptance_evidence_items_v _evs "${_evl%% covers: *}"
        for ev in "${_evs[@]+"${_evs[@]}"}"; do
            printf '  Evidence: %s — open the file and read the code around that text\n' "$ev"
        done
    done <<< "$blk"
    return 0
}
