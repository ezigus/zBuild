#!/usr/bin/env bash
# scripts/lib/stage-time-limit.sh — the whole-stage time limit (ADR-063, amended
# 2026-10-15). Read from the loaded template (_TPL_SOURCE_FILE, exported by
# load_template), so every dispatch arm — the map arm's generated script
# included — sees the same value.
#
# Sourced library: inherits the caller's shell options; do NOT add set -euo.

[[ -n "${_ZBUILD_STAGE_TIME_LIMIT_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_TIME_LIMIT_LOADED=1

# Per-stage `timeout_s:` — how long the engine lets the WHOLE stage run before
# it stops it (every model call, check and retry inside it). Not router.timeout_s,
# which bounds one model call. 900 seconds (15 minutes) when unset. Read lazily
# from the template source, like template_stage_retry.
template_stage_time_limit() {
    local _tstl; template_stage_time_limit_v _tstl "$1"; printf '%s' "$_tstl"
}
# template_stage_time_limit_v <var> <stage> — the same into <var>. One read of
# the template gives every stage's limit (template_stage_time_limits_load), and
# load_template makes that read in the runner's shell, so every dispatch
# inherits it (ADR-065 §5): asked per stage, the read was redone in each
# dispatch's subshell.
declare -gA _ZB_STAGE_TL_MEMO=()   # "<template>\034<stage>" → its timeout_s text; "<template>\034" → read
template_stage_time_limit_v() {
    local -n _tstv="$1"
    template_stage_time_limits_load
    _tstv="${_ZB_STAGE_TL_MEMO["${_TPL_SOURCE_FILE:-}"$'\034'"$2"]:-}"
    [[ "$_tstv" =~ ^[1-9][0-9]*$ ]] || _tstv=900
}

# template_stage_time_limits_load [force] — every stage's `timeout_s:` from the
# template, in one pass, into _ZB_STAGE_TL_MEMO; once per template unless forced.
# A stage's limit is its block's own `timeout_s:` one level in: the block opens
# at `<stage>:` in column 0, or two deep under `stage_definitions:`, and closes
# at the next line no deeper than its header; the first such line wins, and a
# block can open again further down. Every stage is followed at once, rule for
# rule as the per-stage reader this replaces (tests/unit/shell-work-cost-test.sh
# W5 holds the two equal).
template_stage_time_limits_load() {
    local f="${_TPL_SOURCE_FILE:-}"
    [[ -n "$f" ]] || return 0
    local k
    if [[ "${1:-}" == force ]]; then
        for k in "${!_ZB_STAGE_TL_MEMO[@]}"; do
            [[ "$k" == "$f"$'\034'* ]] && unset "_ZB_STAGE_TL_MEMO[$k]"
        done
    fi
    [[ -n "${_ZB_STAGE_TL_MEMO["$f"$'\034']+x}" ]] && return 0
    _ZB_STAGE_TL_MEMO["$f"$'\034']=1
    [[ -f "$f" ]] || return 0
    local line lead li in_defs=0 s s1 s4 s4_was v
    local -A open=() ind=() found=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^stage_definitions:[[:space:]]*$ ]]; then in_defs=1; continue; fi
        lead="${line%%[! ]*}"; li=${#lead}
        s1=""; [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_.-]*):[[:space:]]*$ ]] && s1="${BASH_REMATCH[1]}"
        (( in_defs )) && [[ "$line" =~ ^[a-zA-Z_] ]] && in_defs=0
        s4=""; (( in_defs )) && [[ "$line" =~ ^\ \ ([A-Za-z_][A-Za-z0-9_.-]*):[[:space:]]*$ ]] && s4="${BASH_REMATCH[1]}"
        s4_was="${s4:+${open[$s4]:-}}"
        for s in "${!open[@]}"; do
            if [[ "$line" =~ [^[:space:]] ]] && (( li <= ind[$s] )); then unset 'open[$s]'; continue; fi
            if (( li == ind[$s] + 2 )) && [[ "$line" =~ ^[[:space:]]+timeout_s:[[:space:]]* ]]; then
                v="${line:${#BASH_REMATCH[0]}}"
                if [[ "$v" == *#* ]]; then v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"; fi
                _ZB_STAGE_TL_MEMO["$f"$'\034'"$s"]="${v//[[:space:]]/}"
                found[$s]=1; unset 'open[$s]'
            fi
        done
        if [[ -n "$s1" && -z "${found[$s1]:-}" ]]; then open[$s1]=1; ind[$s1]=0; fi
        if [[ -n "$s4" && -z "${found[$s4]:-}" && -z "$s4_was" ]]; then open[$s4]=1; ind[$s4]=2; fi
    done 2>/dev/null < "$f"
}
