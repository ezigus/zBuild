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
# template_stage_time_limit_v <var> <stage> — the same into <var>, read once
# per (template, stage) per shell: the engine asks on every dispatch, and the
# template does not change during a run (ADR-065 §5).
declare -gA _ZB_STAGE_TL_MEMO=()
template_stage_time_limit_v() {
    local -n _tstv="$1"
    local _k="${_TPL_SOURCE_FILE:-}"$'\034'"$2"
    if [[ -n "${_ZB_STAGE_TL_MEMO[$_k]:-}" ]]; then _tstv="${_ZB_STAGE_TL_MEMO[$_k]}"; return 0; fi
    _tstv="$(_template_stage_time_limit_read "$2")"
    _ZB_STAGE_TL_MEMO[$_k]="$_tstv"
}
_template_stage_time_limit_read() {
    local stage_id="$1" v=""
    if [[ -n "${_TPL_SOURCE_FILE:-}" && -f "${_TPL_SOURCE_FILE}" ]]; then
        # Read by the shell, rule for rule as the awk it replaced (ADR-065 §5):
        # `<stage>:` at column 0, or two deep under `stage_definitions:`, then
        # its own `timeout_s:` one level in.
        local line lead ind in_block=0 block_ind=0 in_defs=0
        local re_top="^${stage_id}:[[:space:]]*$" re_def="^  ${stage_id}:[[:space:]]*$"
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ $re_top ]]; then in_block=1; block_ind=0; in_defs=0; continue; fi
            if [[ "$line" =~ ^stage_definitions:[[:space:]]*$ ]]; then in_defs=1; continue; fi
            (( in_defs )) && [[ "$line" =~ ^[a-zA-Z_] ]] && in_defs=0
            if (( in_defs && !in_block )) && [[ "$line" =~ $re_def ]]; then in_block=1; block_ind=2; continue; fi
            (( in_block )) || continue
            lead="${line%%[! ]*}"; ind=${#lead}
            if [[ "$line" =~ [^[:space:]] ]] && (( ind <= block_ind )); then in_block=0; continue; fi
            if (( ind == block_ind + 2 )) && [[ "$line" =~ ^[[:space:]]+timeout_s:[[:space:]]* ]]; then
                v="${line:${#BASH_REMATCH[0]}}"
                if [[ "$v" == *#* ]]; then v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"; fi
                v="${v//[[:space:]]/}"
                break
            fi
        done 2>/dev/null < "${_TPL_SOURCE_FILE}"
    fi
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || v=900
    printf '%s' "$v"
}

