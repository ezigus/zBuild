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
    local stage_id="$1" v=""
    if [[ -n "${_TPL_SOURCE_FILE:-}" && -f "${_TPL_SOURCE_FILE}" ]]; then
        v="$(awk -v stage="$stage_id" '
            function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
            $0 ~ "^"stage":[[:space:]]*$" { in_block = 1; block_ind = 0; in_defs = 0; next }
            /^stage_definitions:[[:space:]]*$/ { in_defs = 1; next }
            in_defs && /^[a-zA-Z_]/ { in_defs = 0 }
            in_defs && !in_block && $0 ~ "^  "stage":[[:space:]]*$" { in_block = 1; block_ind = 2; next }
            in_block {
                ind = indent($0)
                if ($0 ~ /[^[:space:]]/ && ind <= block_ind) { in_block = 0 }
            }
            in_block && indent($0) == block_ind + 2 && $0 ~ "^[[:space:]]+timeout_s:" {
                sub(/^[[:space:]]+timeout_s:[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); gsub(/[[:space:]]/, "")
                print; exit
            }
        ' "${_TPL_SOURCE_FILE}" 2>/dev/null)"
    fi
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || v=900
    printf '%s' "$v"
}

