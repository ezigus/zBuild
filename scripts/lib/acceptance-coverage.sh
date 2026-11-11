#!/usr/bin/env bash
# acceptance-coverage.sh — Level-1 of the acceptance-contract gate (ADR-036, #922).
#
# Verifies that every stable SPEC-n id declared in a design.md ```acceptance
# block has at least one assertion in the test folders whose label contains its
# tag (#2508: the file is found by the tag — design names none). This is the cheap, mechanical
# tag-presence check that runs before the (expensive) Level-2 negative control.
#
# Source-only (pure functions, no side effects). Like acceptance-block.sh it
# deliberately does NOT `set -euo pipefail` at top level — that would mutate the
# options of any caller that sources it.

[[ -n "${_ACCEPTANCE_COVERAGE_LOADED:-}" ]] && return 0
_ACCEPTANCE_COVERAGE_LOADED=1

_ACCEPTANCE_COVERAGE_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
# shellcheck source=./acceptance-block.sh
source "$_ACCEPTANCE_COVERAGE_DIR/acceptance-block.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" acceptance-block.sh"

# acceptance_coverage_spec_tagged <design_md> <repo_root> <spec_id>
# Returns 0 if a file in the test folders holds the SPEC's tag; 1 otherwise.
acceptance_coverage_spec_tagged() {
    local design_md="${1:-}" repo_root="${2:-}" spec_id="${3:-}"
    [[ -z "$design_md" || -z "$spec_id" ]] && return 1
    local -A _cst=()
    acceptance_spec_files_v _cst "$design_md" "${repo_root:-}"
    [[ -n "${_cst[$spec_id]:-}" ]]
}

# _acceptance_trim_label <line>  (#1684)
# Strips leading whitespace and truncates to 100 chars with '…'.
_acceptance_trim_label() {
    local s="${1-}"
    s="${s#"${s%%[![:space:]]*}"}"
    if [[ ${#s} -gt 100 ]]; then
        printf '%s…\n' "${s:0:100}"
    else
        printf '%s\n' "$s"
    fi
}

# acceptance_find_assertion_label <repo_root> <spec_id> <testfiles...>  (#1684)
# Echoes the label of an assertion that actually runs for <spec_id>, trimmed by
# _acceptance_trim_label. Empty string when the tag appears nowhere.
#
# Two passes, and the reason is the whole point of this function. These testfiles
# routinely contain [<spec_id>] as FIXTURE text — tests-of-the-gate write sandbox
# repos whose bodies carry tags, and a fixture line is not an assertion. Taking
# the first textual match therefore reports a label that was never asserted,
# which is worse than reporting nothing: it reads as confirmation. Pass 1 takes
# the first line that INVOKES an assertion helper; only when no declared file has
# one does pass 2 fall back to any tagged line.
#
# Residual: SPEC ids are file-global, so a file carrying the same id for a
# DIFFERENT design's SPEC can still win pass 1 — see #1691.
# _acceptance_strip_comment <line>
# Drops a trailing comment, but only a real one. Comments are how a SPEC
# sentence leaks into an assertion and buys a false `corresponds`, so they must
# go — but a naive split on '#' also severs any assertion message containing
# one, which corrupts the very text being judged. Track quoting; cut only a '#'
# that actually starts a comment.
_acceptance_strip_comment() { local _asc; _acceptance_strip_comment_v _asc "${1-}"; printf '%s' "$_asc"; }

# _acceptance_strip_comment_v <var> <line> [headings] — the same into <var>, in
# this shell (ADR-065 §5: it runs on every line of a test file). With headings,
# a comment line that is a section heading — its first word Given, When, Then,
# And or Cleanup, in any case and formatting — is kept as written (#2474,
# ADR-073 §6): the check is asked about the sections, so it must see them.
_acceptance_strip_comment_v() {
    local -n _ascv="$1"
    local _asc_line="${2-}" _asc_out="" _asc_q="" _asc_c _asc_i=0 _asc_n _asc_t
    if [[ -n "${3:-}" ]]; then
        _asc_t="${_asc_line#"${_asc_line%%[![:space:]]*}"}"
        if [[ "$_asc_t" == "#"* && "$_asc_t" != "#!"* && "${_asc_t#\#}" =~ ^[[:space:]*_\`#]*([A-Za-z]+)([^A-Za-z]|$) ]]; then
            case "${BASH_REMATCH[1],,}" in
                given|when|then|and|cleanup) _ascv="${_asc_line%"${_asc_line##*[![:space:]]}"}"; return 0 ;;
            esac
        fi
    fi
    # Separate statement: bash expands every word of a `local` BEFORE the
    # locals exist, so `_asc_n=${#_asc_line}` on the line that assigns
    # `_asc_line` reads the OUTER scope and silently yields 0 — the loop then never runs.
    _asc_n=${#_asc_line}
    while (( _asc_i < _asc_n )); do
        _asc_c="${_asc_line:_asc_i:1}"
        if [[ -n "$_asc_q" ]]; then
            [[ "$_asc_c" == "$_asc_q" ]] && _asc_q=""
            _asc_out+="$_asc_c"
        elif [[ "$_asc_c" == '"' || "$_asc_c" == "'" ]]; then
            _asc_q="$_asc_c"; _asc_out+="$_asc_c"
        elif [[ "$_asc_c" == "#" ]] && { (( _asc_i == 0 )) || [[ "${_asc_line:_asc_i-1:1}" == [[:space:]] ]]; }; then
            break
        else
            _asc_out+="$_asc_c"
        fi
        (( _asc_i++ ))
    done
    _ascv="${_asc_out%"${_asc_out##*[![:space:]]}"}"
}

# ─── acceptance_find_assertion_sources <repo_root> <spec_id> <testfiles...> ──
# EVERY assertion tagged with the SPEC, in full, with its enclosing stanza.
#
# Distinct from acceptance_find_assertion_label above, which is the OPERATOR
# readout: first match, trimmed to 100 chars. Judging correspondence from that
# fragment is garbage-in — the repo's dominant shape is
# `if <predicate>; then assert_pass "[SPEC-n] …"`, where all the meaning lives
# in the predicate. Stripping it leaves a bare label that reads as a vacuous
# test, and a reader will (correctly) report exactly that about the mutilation.
#
# The stanza is the contiguous non-blank run containing the tagged line, and
# the test's setup travels with it: every line above it back to the previous
# assertion's stanza, blank lines or not (#1944 run 40329284881: a judge shown
# the stanza alone called it partial for what its setup established). The
# tagged checks are marked ">> ", every line of each (#2460: a check is the whole
# command, however many lines it spans). Comments are stripped: pasting the SPEC
# sentence beside a weak assertion is the one gaming vector this input has.
acceptance_find_assertion_sources() {
    local repo_root="${1:-}" spec_id="${2:-}"; shift 2
    local tf abs i n a b j line first=1 tag u
    for tf in "$@"; do
        [[ -z "$tf" ]] && continue
        abs="$repo_root/$tf"
        [[ -f "$abs" ]] || continue
        local -a lines=() ustart=() uend=() ucheck=() utext=()
        while IFS= read -r line || [[ -n "$line" ]]; do lines+=("$line"); done < "$abs"
        n=${#lines[@]}
        _acceptance_check_units
        local -a starts=()
        tag="$(acceptance_spec_tag "$spec_id")"
        for (( i = 0; i < n; i++ )); do
            # #2460: a check is the whole command, however many lines it spans.
            (( ucheck[i] && ustart[i] == i )) || continue
            [[ "${utext[i]}" == *"$tag"* ]] || continue
            a=$i; while (( a > 0 )) && [[ -n "${lines[a-1]// }" ]]; do (( a-- )); done
            b=${uend[i]}; while (( b < n - 1 )) && [[ -n "${lines[b+1]// }" ]]; do (( b++ )); done
            # The setup: back to the end of the previous check's stanza.
            j=$(( a - 1 ))
            while (( j >= 0 )) && ! (( ucheck[j] )); do (( j-- )); done
            if (( j >= 0 )); then
                while (( j < a - 1 )) && [[ -n "${lines[j+1]// }" ]]; do (( j++ )); done
                a=$(( j + 1 ))
            else
                a=0
            fi
            # One stanza is emitted once however many tagged checks it holds.
            local seen=0 s
            for s in ${starts[@]+"${starts[@]}"}; do [[ "$s" == "$a:$b" ]] && seen=1; done
            (( seen )) && continue
            starts+=("$a:$b")
            (( first )) || printf '\n'
            first=0
            for (( ; a <= b; a++ )); do
                _acceptance_strip_comment_v line "${lines[a]}"
                [[ -n "${line// }" ]] || continue
                u=${ustart[a]}
                if (( ucheck[u] )) && [[ "${utext[u]}" == *"$tag"* ]]; then
                    line=">> ${line#"${line%%[![:space:]]*}"}"
                fi
                printf '%s\n' "$line"
            done
        done
    done
    return 0
}

# _acceptance_check_units — over the caller's lines[] (and n), each line's unit:
# ustart[i]/uend[i] the first and last line of the command it belongs to (a line
# ending in a backslash continues onto the next), ucheck[i] 1 when that command
# is a check (`assert…`), and utext[start] the command's lines joined (#2460).
_acceptance_check_units() {
    local _i=0 _s _t _l
    while (( _i < n )); do
        _s=$_i; _t="${lines[_i]}"
        while :; do
            _l="${lines[_i]}"; _l="${_l%"${_l##*[![:space:]]}"}"
            [[ "$_l" == *\\ ]] && (( _i < n - 1 )) || break
            (( _i++ )); _t+=$'\n'"${lines[_i]}"
        done
        local _c=0; [[ "${lines[_s]}" =~ ^[[:space:]]*assert[a-z_]*([[:space:]]|$) ]] && _c=1
        for (( _k = _s; _k <= _i; _k++ )); do ustart[_k]=$_s; uend[_k]=$_i; ucheck[_k]=$_c; done
        utext[_s]="$_t"
        (( _i++ ))
    done
}

# ─── acceptance_testfile_source <repo_root> <testfile> <tag>... ─────────────
# The whole test file, comments stripped but its section headings kept (#2474),
# with each assertion tagged by one of
# <tag>s marked ">> " (#2450) — every line of it, however many it spans (#2460).
# The stanza view above shows an assertion's own
# setup; setup that lives elsewhere — a helper function, a block shared by
# several cases — reaches the check only from the file itself (#1805 run
# 41365460329: the check called tests partial for code it was not shown).
acceptance_testfile_source() {
    local repo_root="${1:-}" tf="${2:-}"; shift 2
    local abs="$repo_root/$tf" line out t marked i u
    [[ -n "$tf" && -f "$abs" ]] || return 0
    local -a lines=() ustart=() uend=() ucheck=() utext=()
    while IFS= read -r line || [[ -n "$line" ]]; do lines+=("$line"); done < "$abs"
    local n=${#lines[@]}
    _acceptance_check_units
    for (( i = 0; i < n; i++ )); do
        _acceptance_strip_comment_v out "${lines[i]}" headings
        [[ -n "${out// }" ]] || continue
        marked=0; u=${ustart[i]}
        if (( ucheck[u] )); then
            for t in "$@"; do [[ "${utext[u]}" == *"$t"* ]] && { marked=1; break; }; done
        fi
        (( marked )) && out=">> ${out#"${out%%[![:space:]]*}"}"
        printf '%s\n' "$out"
    done
    return 0
}

acceptance_find_assertion_label() {
    local repo_root="${1:-}" spec_id="${2:-}"; shift 2
    local pass tf abs match tag i line
    tag="$(acceptance_spec_tag "$spec_id")"
    for pass in assert any; do
        for tf in "$@"; do
            [[ -z "$tf" ]] && continue
            abs="$repo_root/$tf"
            [[ -f "$abs" ]] || continue
            match=""
            if [[ "$pass" == "assert" ]]; then
                # #2460: the check whose command — over however many lines —
                # carries the tag, read whole.
                local -a lines=() ustart=() uend=() ucheck=() utext=()
                while IFS= read -r line || [[ -n "$line" ]]; do lines+=("$line"); done < "$abs"
                local n=${#lines[@]}
                _acceptance_check_units
                for (( i = 0; i < n; i++ )); do
                    (( ucheck[i] && ustart[i] == i )) || continue
                    [[ "${utext[i]}" == *"$tag"* ]] || continue
                    match="${utext[i]//\\$'\n'/ }"; match="${match//$'\n'/ }"
                    break
                done
            else
                match="$(grep -m1 -F "$tag" "$abs" 2>/dev/null || true)"
            fi
            if [[ -n "$match" ]]; then
                _acceptance_trim_label "$match"
                return 0
            fi
        done
    done
    return 0
}

# acceptance_coverage_check <design_md> <repo_root>
# Level-1 gate over the code SPEC-n ids in the design's acceptance block.
# Prints one "UNTAGGED <spec_id>" line per spec with no backing tagged
# assertion. Returns 0 when every gated SPEC-n is tagged (or there are no
# SPEC-n ids / no acceptance block — those are handled as a no-op pass by the
# caller), 1 when at least one gated SPEC-n is untagged.
#
# #2517 (ADR-069): every requirement, whatever its status, is proven by a test
# that passes at the end, so every one needs its tagged test. Only a [code]
# requirement's test must also fail on the old code (the negative control).
acceptance_coverage_check() {
    local design_md="${1:-}" repo_root="${2:-}"
    local spec_id rc=0
    # #2508: every SPEC's test files, found by tag once.
    local -A _acc_files=()
    acceptance_spec_files_v _acc_files "$design_md" "${repo_root:-}"
    while IFS= read -r spec_id; do
        [[ -z "$spec_id" ]] && continue
        if [[ -z "${_acc_files[$spec_id]:-}" ]]; then
            printf 'UNTAGGED %s\n' "$spec_id"
            rc=1
        fi
    done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)
    return "$rc"
}
