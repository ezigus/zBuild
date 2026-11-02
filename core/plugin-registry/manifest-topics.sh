#!/usr/bin/env bash
# core/plugin-registry/manifest-topics.sh — a manifest's topics: what each
# output is about, what the stage takes, and where a stage result's findings
# may go (ADR-071).
#
# Split from manifest-validation.sh, which sources it, to keep that file from
# growing. Sourced library: inherits the caller's shell options; uses the
# caller's `error` and ZBUILD_STAGE_TOPICS.

[[ -n "${_ZBUILD_MANIFEST_TOPICS_LOADED:-}" ]] && return 0
_ZBUILD_MANIFEST_TOPICS_LOADED=1

# _manifest_validate_topics <manifest> — rc is the number of problems found,
# each reported with `error`. A take is { topic, for }; an output that names a
# topic has a description (#2428); a stage result — `primary: true`, or a path
# ending -result.json — declares `finding_topics:`, the topics its findings may
# name for themselves, or `none` (#2454: nothing made a stage decide, and the
# test stage sent every failing test to test-author). Plain bash, no fork: this
# runs for every plugin at load (ADR-065).
_manifest_validate_topics() {
    local manifest="$1" errors=0
    local _tl _tw _tin=0 _tkin=0 _tbad _tk="" _tkfor=0 _oid="" _otopic=0 _odesc=0 _oitem=0
    local _oresult=0 _oft=0 _fw
    local -a _tgaps=()
    while IFS= read -r _tl || [[ -n "$_tl" ]]; do
        if [[ "$_tl" =~ ^[a-zA-Z_] ]]; then
            [[ -n "$_tk" && $_tkfor -eq 0 ]] && _tgaps+=("take '$_tk' has no for:")
            _manifest_topics_item_gaps
            _tk=""; _tkfor=0; _oid=""; _otopic=0; _odesc=0; _oitem=0; _oresult=0; _oft=0; _tin=0; _tkin=0
        fi
        [[ "$_tl" =~ ^outputs:[[:space:]]*$ ]] && { _tin=1; continue; }
        if [[ "$_tl" =~ ^takes:[[:space:]]*$ ]]; then _tkin=1; continue; fi
        _tbad=""
        if [[ "$_tl" =~ ^takes: ]]; then
            error "validate_manifest($manifest): takes: is a list of { topic, for } entries (ADR-071), e.g.
takes:
  - topic: ask
    for: the issue and requirements to work from"
            errors=$((errors + 1))
        elif (( _tkin )) && [[ "$_tl" =~ ^[[:space:]]*-[[:space:]]+topic:[[:space:]]*([^[:space:]#]*) ]]; then
            [[ -n "$_tk" && $_tkfor -eq 0 ]] && _tgaps+=("take '$_tk' has no for:")
            _tk="${BASH_REMATCH[1]}"; _tkfor=0
            [[ " ${ZBUILD_STAGE_TOPICS[*]} " == *" $_tk "* ]] || _tbad="takes '$_tk' "
        elif (( _tkin )) && [[ "$_tl" =~ ^[[:space:]]+for:[[:space:]]*[^[:space:]] ]]; then
            _tkfor=1
        elif (( _tin )) && [[ "$_tl" =~ ^[[:space:]]*-[[:space:]] ]]; then
            _manifest_topics_item_gaps
            _oitem=1; _oid=""; _otopic=0; _odesc=0; _oresult=0; _oft=0
            [[ "$_tl" =~ ^[[:space:]]*-[[:space:]]+id:[[:space:]]*([^[:space:]#]*) ]] && _oid="${BASH_REMATCH[1]}"
        elif (( _tin )) && [[ "$_tl" =~ ^[[:space:]]+id:[[:space:]]*([^[:space:]#]*) ]]; then
            _oid="${BASH_REMATCH[1]}"
        elif (( _tin )) && [[ "$_tl" =~ ^[[:space:]]+description:[[:space:]]*[^[:space:]] ]]; then
            _odesc=1
        elif (( _tin )) && [[ "$_tl" =~ ^[[:space:]]+topic:[[:space:]]*([^[:space:]#]*) ]]; then
            _tw="${BASH_REMATCH[1]}"; _otopic=1
            [[ " ${ZBUILD_STAGE_TOPICS[*]} " == *" $_tw "* ]] || _tbad="topic '$_tw' "
        elif (( _tin )) && [[ "$_tl" =~ ^[[:space:]]+primary:[[:space:]]*true ]]; then
            _oresult=1
        elif (( _tin )) && [[ "$_tl" =~ ^[[:space:]]+path:.*-result\.json ]]; then
            _oresult=1
        elif (( _tin )) && [[ "$_tl" =~ ^[[:space:]]+finding_topics:[[:space:]]*([^#]*) ]]; then
            _oft=1
            local -a _fws; read -ra _fws <<< "${BASH_REMATCH[1]}"
            if [[ ${#_fws[@]} -eq 0 ]]; then
                _tbad="finding_topics '' "
            elif [[ "${_fws[*]}" != none ]]; then
                for _fw in "${_fws[@]}"; do
                    [[ " ${ZBUILD_STAGE_TOPICS[*]} " == *" $_fw "* ]] && continue
                    error "validate_manifest($manifest): finding_topics '$_fw' is not one of: ${ZBUILD_STAGE_TOPICS[*]} (ADR-071)"
                    errors=$((errors + 1))
                done
            fi
        fi
        if [[ -n "$_tbad" ]]; then
            error "validate_manifest($manifest): ${_tbad% } is not one of: ${ZBUILD_STAGE_TOPICS[*]} (ADR-071)"
            errors=$((errors + 1))
        fi
    done < "$manifest"
    [[ -n "$_tk" && $_tkfor -eq 0 ]] && _tgaps+=("take '$_tk' has no for:")
    _manifest_topics_item_gaps
    for _tw in "${_tgaps[@]}"; do
        error "validate_manifest($manifest): $_tw — a stage states what it takes and what each output holds (ADR-071)"
        errors=$((errors + 1))
    done
    return "$errors"
}

# What the output item just read lacks; reads and appends to the caller's locals.
_manifest_topics_item_gaps() {
    (( _oitem )) || return 0
    (( _otopic && ! _odesc )) && _tgaps+=("output '$_oid' has a topic but no description:")
    (( _oresult && ! _oft )) && _tgaps+=("output '$_oid' is a stage result and declares no finding_topics: (the topics its findings may go to, or none)")
    return 0
}
