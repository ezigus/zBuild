#!/usr/bin/env bash
# core/plugin-registry/manifest-calls.sh — every model call a stage makes, by
# name, with its tools in zbuild's words (#2507, ADR-017 §12).
#
#   calls:
#     main: [read-files, edit-files, run-commands, web-search, subagents, todo-list]
#     coverage: [read-files, read-git, web-search, subagents]
#
# `main` is the stage's own call; a check inside the stage names its call with
# ZBUILD_ROUTE_CALL. A call that lists no words (`[]`) has no tools. The words
# are zbuild's: each provider module turns them into its own
# (provider_<name>_tool_args, ADR-003).
#
# Two readers, one parse: validate_manifest (the loud gate, at load) and the
# router (core/router/call-tools.sh, on every call). Read by the shell: no
# program on either path (ADR-065 §5). Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_MANIFEST_CALLS_LOADED:-}" ]] && return 0
_ZBUILD_MANIFEST_CALLS_LOADED=1

# The words a call's tools are named in. mcp is a word no call is given yet:
# how a manifest names the servers a call may use is a later decision.
_ZB_TOOL_WORDS="read-files edit-files run-commands read-git web-search subagents todo-list mcp"

# manifest_calls_v <var> <manifest> — each call the manifest lists, one
# "<name> <word>..." line (a call with no words is its name alone); a line the
# shell cannot read as a list is "<name> !<value as written>". Empty when the
# manifest lists none.
manifest_calls_v() {
    local -n _mco="$1"; local _mc_mf="${2:-}"
    _mco=""
    [[ -n "$_mc_mf" && -f "$_mc_mf" ]] || return 0
    local _mc_l _mc_in=0 _mc_k _mc_v _mc_w _mc_out=""
    local -a _mc_ws=()
    while IFS= read -r _mc_l || [[ -n "$_mc_l" ]]; do
        if [[ "$_mc_l" =~ ^calls:[[:space:]]*(#.*)?$ ]]; then _mc_in=1; continue; fi
        (( _mc_in )) || continue
        [[ "$_mc_l" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        [[ "$_mc_l" =~ ^[^[:space:]] ]] && break
        [[ "$_mc_l" =~ ^[[:space:]]+([A-Za-z0-9_-]+):[[:space:]]*(.*)$ ]] || continue
        _mc_k="${BASH_REMATCH[1]}"; _mc_v="${BASH_REMATCH[2]}"
        [[ "$_mc_v" == *'#'* ]] && _mc_v="${_mc_v%%#*}"
        _mc_v="${_mc_v%"${_mc_v##*[![:space:]]}"}"
        if [[ ! "$_mc_v" =~ ^\[(.*)\]$ ]]; then _mc_out+="$_mc_k !${_mc_v}"$'\n'; continue; fi
        _mc_v="${BASH_REMATCH[1]//,/ }"
        read -ra _mc_ws <<< "$_mc_v"
        _mc_out+="$_mc_k"
        for _mc_w in ${_mc_ws[@]+"${_mc_ws[@]}"}; do _mc_w="${_mc_w#[\"\']}"; _mc_out+=" ${_mc_w%[\"\']}"; done
        _mc_out+=$'\n'
    done < "$_mc_mf"
    _mco="$_mc_out"
}

# manifest_call_words_v <var> <manifest> <call> — the call's words, space
# separated (empty for a call that lists none). rc 1 when the manifest does not
# list the call.
manifest_call_words_v() {
    local -n _mcw="$1"; local _mcw_all _mcw_l
    _mcw=""
    manifest_calls_v _mcw_all "$2"
    while IFS= read -r _mcw_l; do
        [[ -n "$_mcw_l" ]] || continue
        if [[ "$_mcw_l" == "$3" ]]; then return 0; fi
        if [[ "$_mcw_l" == "$3 "* ]]; then _mcw="${_mcw_l#"$3 "}"; return 0; fi
    done <<< "$_mcw_all"
    return 1
}

# _manifest_validate_calls <manifest> — validate_manifest's check of the block:
# each call a list of known words. Prints each problem with `error`; returns
# the number found.
_manifest_validate_calls() {
    local _vc_mf="$1" _vc_all _vc_l _vc_k _vc_w _vc_n=0
    local -a _vc_ws=()
    manifest_calls_v _vc_all "$_vc_mf"
    while IFS= read -r _vc_l; do
        [[ -n "$_vc_l" ]] || continue
        _vc_k="${_vc_l%% *}"
        if [[ "$_vc_l" == "$_vc_k !"* ]]; then
            error "validate_manifest($_vc_mf): calls.$_vc_k must be a list of tool words, e.g. [read-files, read-git], or [] for none — got: ${_vc_l#"$_vc_k !"}"
            _vc_n=$((_vc_n + 1)); continue
        fi
        [[ "$_vc_l" == *" "* ]] || continue
        read -ra _vc_ws <<< "${_vc_l#"$_vc_k "}"
        for _vc_w in "${_vc_ws[@]}"; do
            [[ " $_ZB_TOOL_WORDS " == *" $_vc_w "* ]] && continue
            error "validate_manifest($_vc_mf): calls.$_vc_k names '$_vc_w', which is not a tool word (valid: $_ZB_TOOL_WORDS)"
            _vc_n=$((_vc_n + 1))
        done
    done <<< "$_vc_all"
    return "$_vc_n"
}
