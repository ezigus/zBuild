#!/usr/bin/env bash
# scripts/lib/stage-retry.sh — the engine runs a stage again (ADR-054 §6a,
# amended 2026-10-31, #2439). The one retry there is: a stage never repeats a
# model call itself, and every stage, however it is run, is run through
# plugin_hook_call, which asks stage_retry_next after each try.
#
# Read from the loaded template (_TPL_SOURCE_FILE, exported by load_template),
# like the stage time limit, so the map arm's generated script sees it too.
#
# Sourced library: inherits the caller's shell options; do NOT add set -euo.

[[ -n "${_ZBUILD_STAGE_RETRY_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_RETRY_LOADED=1

_ZB_SR_ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." 2>/dev/null && pwd)"

# Per-stage `retry:` — how many times the engine runs a stage again when its
# outcome says retry. Prints nothing when unset.
template_stage_retry() {
    local stage_id="$1"
    [[ -n "${_TPL_SOURCE_FILE:-}" && -f "${_TPL_SOURCE_FILE}" ]] || return 0
    awk -v stage="$stage_id" '
        function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
        $0 ~ "^"stage":[[:space:]]*$" { in_block = 1; block_ind = 0; in_defs = 0; next }
        /^stage_definitions:[[:space:]]*$/ { in_defs = 1; next }
        in_defs && /^[a-zA-Z_]/ { in_defs = 0 }
        in_defs && !in_block && $0 ~ "^  "stage":[[:space:]]*$" { in_block = 1; block_ind = 2; next }
        in_block {
            ind = indent($0)
            if ($0 ~ /[^[:space:]]/ && ind <= block_ind) { in_block = 0 }
        }
        in_block && indent($0) == block_ind + 2 && $0 ~ "^[[:space:]]+retry:" {
            sub(/^[[:space:]]+retry:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, ""); gsub(/[[:space:]]/, "")
            print; exit
        }
    ' "${_TPL_SOURCE_FILE}" 2>/dev/null
}

# stage_retry_budget_v <var> <stage> — the template's `retry:`, else 1; capped
# at 5. A value that is not a number is the default.
stage_retry_budget_v() {
    local -n _srb="$1"
    _srb="$(template_stage_retry "${2:-}" 2>/dev/null || true)"
    [[ "$_srb" =~ ^[0-9]+$ ]] || _srb=1
    (( _srb > 5 )) && _srb=5
    return 0
}

_stage_retry_load() {
    declare -F runner_read_stage_disposition_v >/dev/null 2>&1 \
        || source "$_ZB_SR_ROOT/core/pipeline/verdict.sh" 2>/dev/null || return 1
    declare -F _router_throttle_observed >/dev/null 2>&1 \
        || source "$_ZB_SR_ROOT/scripts/lib/router-rc-classify.sh" 2>/dev/null || true
    declare -F _zbuild_check_abort >/dev/null 2>&1 \
        || source "$_ZB_SR_ROOT/scripts/lib/abort-propagation.sh" 2>/dev/null || true
    return 0
}

# stage_retry_next <plugin_dir> <stage> <state_file> <rc> <tries_so_far> <budget>
# rc 0 when the stage is to run again: its outcome is a retry word, a retry is
# left, no abort is recorded, and the try just made changed something (ADR-054
# §6a; `interrupted` and `throttled` say nothing about the work, so they need
# no change). Announces the retry (stage.retry) and waits when the word says to.
# _ATTEMPT_LAST_PROGRESS is the record of the try just made (attempt-archive.sh);
# a try that left no record counts as having changed something.
stage_retry_next() {
    local plugin_dir="$1" stage="$2" state_file="$3" rc="$4" tries="$5" budget="$6"
    (( tries <= budget )) || return 1
    _stage_retry_load || return 1
    if declare -F _zbuild_check_abort >/dev/null 2>&1 && ! _zbuild_check_abort; then
        return 1
    fi
    local state_dir obs limited=0 outcome=""
    zb_dirname_v state_dir "$state_file"
    dispatch_rc_observation_v obs "$rc" 2>/dev/null || obs=""
    if declare -F _router_throttle_observed >/dev/null 2>&1 && _router_throttle_observed; then limited=1; fi
    runner_read_stage_disposition_v outcome "$state_dir" "$plugin_dir/manifest.yaml" "$stage" "$rc" \
        "$obs" "$limited" 2>/dev/null || outcome=""
    [[ -n "$outcome" ]] && disposition_retryable "$outcome" 2>/dev/null || return 1
    if [[ "$outcome" != interrupted && "$outcome" != throttled \
          && "${_ATTEMPT_LAST_PROGRESS:-}" == "false" ]]; then
        return 1
    fi
    local wait_s; wait_s="$(disposition_wait_s "$outcome" 2>/dev/null || printf '0')"
    [[ "$wait_s" =~ ^[0-9]+$ ]] || wait_s=0
    emit_event "stage.retry" "stage=$stage" "outcome=$outcome" "try=$(( tries + 1 ))" \
        "of=$(( budget + 1 ))" "wait_s=$wait_s" "rc=$rc" 2>/dev/null || true
    (( wait_s > 0 )) && sleep "$wait_s"
    declare -F _router_clear_throttle_marker >/dev/null 2>&1 && _router_clear_throttle_marker
    return 0
}
