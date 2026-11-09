#!/usr/bin/env bash
# core/router/call-tools.sh — the tools of the model call about to be made
# (#2507, ADR-017 §12, ADR-003).
#
# A stage's manifest lists every model call it makes, by name, with its tools in
# zbuild's words (core/plugin-registry/manifest-calls.sh). The call is the
# stage's own (`main`) unless its caller names another with ZBUILD_ROUTE_CALL.
# The provider module turns the words into its own arguments
# (provider_<name>_tool_args); a call outside any stage has no tools. A call the
# manifest does not list, or a word the provider cannot supply, is refused.
#
# The words also decide the guards in the call's PreToolUse hook
# (core/router/tool-hook.sh): read-git without run-commands may run only git's
# reading commands; a call given the copy of the code from before the change
# (ZBUILD_ROUTE_BASE_CODE — test-author's) reads existing code there. The hook
# checks every web search for secrets, needing no word from here.
#
# Sourced by route.sh. Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_CALL_TOOLS_LOADED:-}" ]] && return 0
_ZBUILD_CALL_TOOLS_LOADED=1

_CALL_TOOLS_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=../../scripts/lib/helpers.sh
declare -F zbuild_engine_tmpdir_v >/dev/null 2>&1 || source "$_CALL_TOOLS_DIR/../../scripts/lib/helpers.sh"
# shellcheck source=../plugin-registry/manifest-calls.sh
declare -F manifest_call_words_v >/dev/null 2>&1 || source "$_CALL_TOOLS_DIR/../plugin-registry/manifest-calls.sh"

_ROUTE_TOOL_ARGS=() _ROUTE_HOOK_FLAGS=() _ROUTE_CALL_WORDS="" _ROUTE_CALL_NAME="" _ROUTE_TOOLS_KEY=""

# _route_call_tools_prepare — for the call about to be made: _ROUTE_TOOL_ARGS
# (the provider's arguments), _ROUTE_CALL_WORDS and _ROUTE_HOOK_FLAGS (the
# guards of core/router/tool-hook.sh). Worked out once per stage, call and provider. rc 2,
# saying why, when the call cannot be made.
_route_call_tools_prepare() {
    local call="${ZBUILD_ROUTE_CALL:-main}" dir="${ZBUILD_PLUGIN_DIR:-}" p="${_ROUTE_PROVIDER:-anthropic}"
    local base="${ZBUILD_ROUTE_BASE_CODE:-}" repo="${ZBUILD_REPO_ROOT:-$PWD}"
    local key="$dir|$call|$p|$base|$repo|${_TPL_SOURCE_FILE:-}"
    [[ "$key" == "$_ROUTE_TOOLS_KEY" ]] && return 0
    _ROUTE_TOOLS_KEY="" _ROUTE_TOOL_ARGS=() _ROUTE_HOOK_FLAGS=() _ROUTE_CALL_WORDS="" _ROUTE_CALL_NAME="$call"
    local words="" why=""
    if [[ -n "$dir" ]] && ! manifest_call_words_v words "$dir/manifest.yaml" "$call"; then
        _route_call_refused "$call" undeclared \
            "the ${dir##*/} manifest does not list a model call named '$call' under calls:"
        return 2
    fi
    local fn="provider_${p//-/_}_tool_args" tmp args_f why_f
    # The model lookup loads the provider module; a call made without it (a
    # stubbed lookup) loads it here. The name is checked as the lookup checks it.
    if ! declare -F "$fn" >/dev/null 2>&1 && [[ "$p" =~ ^[a-z][a-z0-9_-]*$ && -f "$_CALL_TOOLS_DIR/providers/$p.sh" ]]; then
        # shellcheck source=providers/anthropic.sh
        source "$_CALL_TOOLS_DIR/providers/$p.sh"
    fi
    if ! declare -F "$fn" >/dev/null 2>&1; then
        _route_call_refused "$call" no_tool_args "provider '$p' has no $fn, so it cannot say which tools a call has"
        return 2
    fi
    # Into files, not $( ): the provider runs in this shell (ADR-065 §5).
    zbuild_engine_tmpdir_v tmp
    args_f="$tmp/.zb-tool-args" why_f="$tmp/.zb-tool-why"
    local -a _ws=()
    read -ra _ws <<< "$words"
    if ! "$fn" ${_ws[@]+"${_ws[@]}"} > "$args_f" 2> "$why_f"; then
        IFS= read -r why < "$why_f" || true
        _route_call_refused "$call" unsupported_tool "${why:-provider '$p' cannot supply the tools '$words'}"
        return 2
    fi
    mapfile -t _ROUTE_TOOL_ARGS < "$args_f"
    _ROUTE_CALL_WORDS="$words"
    _route_call_hook_flags "$words" "$repo" "$base"
    _ROUTE_TOOLS_KEY="$key"
    return 0
}

# _route_call_hook_flags <words> <repo> <base> — the guards the words need.
# The path lists are loaded here, only for a call that needs them.
_route_call_hook_flags() {
    local w=" $1 " g globs
    [[ "$w" == *" read-git "* && "$w" != *" run-commands "* ]] && _ROUTE_HOOK_FLAGS+=(--git-only)
    if [[ -n "$3" && "$w" == *" read-files "* ]]; then
        _ROUTE_HOOK_FLAGS+=(--repo "$2" --code-copy "$3")
        # shellcheck source=../../scripts/lib/test-paths.sh
        declare -F zb_test_path_globs_v >/dev/null 2>&1 || source "$_CALL_TOOLS_DIR/../../scripts/lib/test-paths.sh"
        zb_test_path_globs_v globs "$2"
        local -a _gl=()
        read -ra _gl <<< "$globs"
        for g in ${_gl[@]+"${_gl[@]}"}; do _ROUTE_HOOK_FLAGS+=(--test-glob "$g"); done
    fi
    return 0
}

# _route_call_refused <call> <reason> <why> — the refusal, said and recorded.
_route_call_refused() {
    error "router: refusing the model call '$1' of stage ${ZBUILD_CURRENT_STAGE:-<none>}: $3 (ADR-017 §12)"
    eb_emit_event "router.call.refused" "stage=${ZBUILD_CURRENT_STAGE:-}" "call=$1" "reason=$2" 2>/dev/null || true
}

# route_calls_unsupported_v <var> <models_file> <manifest>... — for each call
# of each manifest whose provider (the one its tier names in <models_file>)
# cannot supply one of its words, a "<stage> call <name>: <why>" line. Empty
# when every word is supplied. Read by the shell: the run checks every stage
# before it starts (ADR-017 §12), and starts no program for it (ADR-065 §6).
route_calls_unsupported_v() {
    local -n _rcu="$1"; local models="$2"; shift 2
    _rcu=""
    local -A prov=()
    local pv mf tier calls l name fn why js=""
    # Each tier's first candidate's provider: the object after "Tn" holds no
    # brace before its candidates' first "provider".
    [[ -f "$models" ]] && { IFS= read -r -d '' js < "$models" || true; }
    local re='"(T[0-4])"[[:space:]]*:[[:space:]]*\{[^}]*"candidates"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{[^}]*"provider"[[:space:]]*:[[:space:]]*"([a-z0-9_-]+)"'
    while [[ "$js" =~ $re ]]; do
        prov[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
        js="${js#*"${BASH_REMATCH[0]}"}"
    done
    for mf in "$@"; do
        [[ -f "$mf" ]] || continue
        manifest_calls_v calls "$mf"
        [[ -n "$calls" ]] || continue
        tier=""
        while IFS= read -r l; do
            [[ "$l" =~ ^[[:space:]]+tier_default:[[:space:]]*\"?(T[0-4]) ]] && { tier="${BASH_REMATCH[1]}"; break; }
        done < "$mf"
        pv="${prov[${tier:-T2}]:-anthropic}"
        fn="provider_${pv//-/_}_tool_args"
        # The provider's module, as _route_provider_load finds it: the runner
        # checks before any router call has loaded one.
        if ! declare -F "$fn" >/dev/null 2>&1 && [[ "$pv" =~ ^[a-z][a-z0-9_-]*$ && -f "$_CALL_TOOLS_DIR/providers/$pv.sh" ]]; then
            # shellcheck source=providers/anthropic.sh
            source "$_CALL_TOOLS_DIR/providers/$pv.sh"
        fi
        while IFS= read -r l; do
            [[ -n "$l" && "$l" != *" !"* ]] || continue
            name="${l%% *}"; why=""
            local -a _ws=()
            [[ "$l" == *" "* ]] && read -ra _ws <<< "${l#* }"
            if ! declare -F "$fn" >/dev/null 2>&1; then
                why="provider '$pv' has no $fn"
            elif ! "$fn" ${_ws[@]+"${_ws[@]}"} >/dev/null 2>&1; then
                # Asked again for its reason: only for a word it cannot supply.
                why="$("$fn" ${_ws[@]+"${_ws[@]}"} 2>&1 >/dev/null)"
                : "${why:=provider '$pv' cannot supply ${_ws[*]}}"
            fi
            if [[ -n "$why" ]]; then local _d="${mf%/manifest.yaml}"; _rcu+="${_d##*/} call $name: ${why%$'\n'}"$'\n'; fi
        done <<< "$calls"
    done
    return 0
}
