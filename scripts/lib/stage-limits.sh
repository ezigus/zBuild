#!/usr/bin/env bash
# scripts/lib/stage-limits.sh — the limits a stage's model calls run under.
#
# One copy, two readers: the router enforces these numbers on every call
# (core/router/route.sh) and the engine states them to the stage in its rules
# (scripts/lib/stage-prompt.sh, ADR-067 §8). A stage told a different budget
# from the one it is killed at works until it is killed.
#
# Sourced library: inherits the caller's shell options; do NOT add set -euo.
[[ -n "${_ZBUILD_STAGE_LIMITS_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_LIMITS_LOADED=1

if ! declare -F manifest_router_knob >/dev/null 2>&1; then
    # shellcheck source=../../core/plugin-registry/manifest-router-budget.sh
    source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd "../.." && pwd)/core/plugin-registry/manifest-router-budget.sh" 2>/dev/null || true
fi

# ─── _route_manifest_knob <knob> — ADR-017 §11 (#1816) manifest layer ───────
# The dispatched plugin's OWN declared default, read from its manifest via the
# dispatch identity the engine exports at plugin_hook_call (ZBUILD_PLUGIN_DIR,
# ADR-054 §3 / #1862). Empty whenever there is no dispatch, no manifest, no
# declaration — or a declaration this router cannot use.
#
# Out-of-range and non-numeric values are IGNORED here, not fatal: the loud
# gate is validate_manifest at load, and a plugin that got past it with a bad
# value must fall back to the constant rather than hand the router a 0-second
# timeout. Fail-safe on the hot path, fail-loud at the boundary.
_route_manifest_knob() {
    local knob="$1"
    local dir="${ZBUILD_PLUGIN_DIR:-}"
    [[ -n "$dir" && -f "$dir/manifest.yaml" ]] || return 0
    declare -F manifest_router_knob >/dev/null 2>&1 || return 0
    local v; v="$(manifest_router_knob "$dir/manifest.yaml" "$knob" 2>/dev/null || true)"
    [[ "$v" =~ ^[0-9]+$ ]] || return 0
    local range; range="$(_manifest_router_range "$knob" 2>/dev/null || true)"
    [[ -n "$range" ]] || return 0
    local min="${range% *}" max="${range#* }"
    [[ "$v" -ge "$min" && "$v" -le "$max" ]] || return 0
    printf '%s' "$v"
}

# ─── _route_stage_tools_v <kind_var> <judge_words_var> [manifest] — #2507 ───
# What a stage's calls may do, from its manifest's `calls:` (ADR-017 §12), for
# the rules it is given (ADR-067 §8): <kind> is `none` when its own call (main)
# has no tools, `judge` when that call can change no file, else `build`; a
# manifest that lists no calls is `build`. <judge_words> are the words of its
# judging call — the first that can change no file — empty when it has none.
_route_stage_tools_v() {
    local -n _rstk="$1" _rstj="$2"
    local mf="${3:-${ZBUILD_PLUGIN_DIR:+$ZBUILD_PLUGIN_DIR/manifest.yaml}}" _rst_all _rst_l _rst_main=""
    _rstk=build _rstj=""
    [[ -n "$mf" && -f "$mf" ]] || return 0
    declare -F manifest_calls_v >/dev/null 2>&1 \
        || source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd "../.." && pwd)/core/plugin-registry/manifest-calls.sh"
    manifest_calls_v _rst_all "$mf"
    [[ -n "$_rst_all" ]] || return 0
    local _rst_seen=0
    while IFS= read -r _rst_l; do
        [[ -n "$_rst_l" && "$_rst_l" != *" !"* ]] || continue
        [[ "${_rst_l%% *}" == main ]] && { _rst_main=" ${_rst_l#main} "; _rst_seen=1; }
        [[ " $_rst_l " == *" edit-files "* || -n "$_rstj" ]] && continue
        [[ "$_rst_l" == *" "* ]] && _rstj="${_rst_l#* }"
    done <<< "$_rst_all"
    (( _rst_seen )) || return 0
    if [[ -z "${_rst_main// /}" ]]; then _rstk=none
    elif [[ "$_rst_main" != *" edit-files "* ]]; then _rstk=judge; fi
    return 0
}

# _route_tools_said_v <var> <words> — what a judging call can do, in words.
_route_tools_said_v() {
    local -n _rts="$1"; local w=" $2 " _rts_l=()
    _rts=""
    [[ "$w" == *" read-files "* ]] && _rts_l+=("open and search files")
    [[ "$w" == *" read-git "* ]] && _rts_l+=("run git diff, git log, git show and git status")
    [[ "$w" == *" web-search "* ]] && _rts_l+=("search the web")
    [[ "$w" == *" subagents "* ]] && _rts_l+=("hand part of the work to a subagent")
    local n=${#_rts_l[@]} i
    for (( i = 0; i < n; i++ )); do
        if (( i == 0 )); then _rts="${_rts_l[i]}"
        elif (( i == n - 1 )); then _rts+=" and ${_rts_l[i]}"
        else _rts+=", ${_rts_l[i]}"; fi
    done
}

# ─── _route_manifest_effort_v <var> [manifest] — #2454 (ADR-017 §11) ────────
# How hard the model thinks on the plugin's calls: its `config.router.effort`,
# else medium. Every call passes it, so no call runs at a default nobody chose.
_ZB_ROUTE_EFFORT_DEFAULT="medium"
_route_manifest_effort_v() {
    local -n _rme="$1"
    _rme="$_ZB_ROUTE_EFFORT_DEFAULT"
    local mf="${2:-${ZBUILD_PLUGIN_DIR:+$ZBUILD_PLUGIN_DIR/manifest.yaml}}"
    [[ -n "$mf" && -f "$mf" ]] || return 0
    declare -F _manifest_router_block_v >/dev/null 2>&1 || return 0
    local _mre; _manifest_router_block_v _mre "$mf" effort
    _mre="${_mre%$'\n'}"
    case "$_mre" in low|medium|high|xhigh|max) _rme="$_mre" ;; esac
    return 0
}

# ─── _route_resolve_knob — ADR-017 (#455) precedence chokepoint ──────────────
# Generic helper: future knobs (tier_default, budget_usd, model_override) reuse
# this. Accessor returns per-stage value or empty; env_var supplies session-wide
# fallback; manifest_knob (#1816) names the plugin's own declared default; the
# compile-time constant is the floor:
#
#   template accessor  >  env var  >  manifest config.router.*  >  constant
#
# The manifest sits BELOW env and template because it is a default, not an
# override: a flow may right-size a stage for a fast lane, and the operator
# escape hatch must still beat both. It sits ABOVE the constant because that is
# what the constant always was — a default nobody could state per stage.
_route_resolve_knob() {
    local accessor_fn="$1" env_var="$2" default_val="$3"
    local override_event="${4:-router.timeout.override_ignored}"
    local manifest_knob="${5:-}"
    local v=""
    if [[ -n "${ZBUILD_CURRENT_STAGE:-}" ]] && declare -F "$accessor_fn" >/dev/null 2>&1; then
        v="$($accessor_fn "$ZBUILD_CURRENT_STAGE" 2>/dev/null || true)"
    fi
    if [[ -n "$v" ]]; then
        # If env var ALSO set and differs, emit override-ignored event for audit.
        # A manifest value losing to template or env is NOT this case: a default
        # being replaced is the design, and eventing it would make every
        # declaring plugin noisy on every dispatch.
        local env_val="${!env_var:-}"
        if [[ -n "$env_val" && "$env_val" != "$v" ]]; then
            eb_emit_event "$override_event" \
                "stage=${ZBUILD_CURRENT_STAGE:-}" \
                "env_var=$env_var" \
                "env_value=$env_val" \
                "applied=$v" 2>/dev/null || true
        fi
        printf '%s\n' "$v"; return 0
    fi
    local env_v="${!env_var:-}"
    if [[ -n "$env_v" ]]; then
        printf '%s\n' "$env_v"; return 0
    fi
    if [[ -n "$manifest_knob" ]]; then
        local mv; mv="$(_route_manifest_knob "$manifest_knob")"
        if [[ -n "$mv" ]]; then
            printf '%s\n' "$mv"; return 0
        fi
    fi
    printf '%s\n' "$default_val"
}

# Concrete: per-stage router.timeout_s > $ZBUILD_ROUTER_TIMEOUT >
# manifest config.router.timeout_s > 300s default.
_route_resolve_timeout() {
    _route_resolve_knob template_stage_router_timeout ZBUILD_ROUTER_TIMEOUT 300 \
        router.timeout.override_ignored timeout_s
}

# ADR-018 (#466): per-stage router.max_turns > $ZBUILD_ROUTER_MAX_TURNS > the
# plugin's own > 0. #2458: 0 — no limit — when nothing sets one; the old 25
# silently capped every stage that named none.
# ADR-029 G3 (#812): when the cycle orchestrator detects a router timeout for
# this stage, it sets ZBUILD_ROUTER_MAX_TURNS_OVERRIDE so the next dispatch
# of the same stage uses an escalated budget (+50%, capped at 2× base). The
# override wins over the per-stage template AND the env knob because that's
# the entire point — escalation must beat the static config that already
# proved too small.
_route_resolve_max_turns() {
    if [[ "${ZBUILD_ROUTER_MAX_TURNS_OVERRIDE:-}" =~ ^[0-9]+$ ]]; then
        printf '%s' "$ZBUILD_ROUTER_MAX_TURNS_OVERRIDE"
        return 0
    fi
    _route_resolve_knob template_stage_router_max_turns ZBUILD_ROUTER_MAX_TURNS 0 \
        router.max_turns.override_ignored max_turns
}

# ADR-018 Amendment N (#762): when max_turns resolves to the 0 sentinel,
# classify which source set it (template > env > manifest > default) for
# telemetry. Emits `template`, `env`, `manifest` (#1816), or `default` (#2458:
# the default is 0, so a stage that sets nothing is `default`).
# Copilot review #764: compare numerically so "00", "000" etc. (accepted
# by the ^[0-9]+$ validator) classify correctly.
_route_classify_max_turns_source() {
    local _tpl_val=""
    if [[ -n "${ZBUILD_CURRENT_STAGE:-}" ]] \
        && command -v template_stage_router_max_turns >/dev/null 2>&1; then
        _tpl_val="$(template_stage_router_max_turns "$ZBUILD_CURRENT_STAGE" 2>/dev/null || true)"
    fi
    local _mf_val; _mf_val="$(_route_manifest_knob max_turns)"
    if [[ "$_tpl_val" =~ ^[0-9]+$ ]] && [[ "$_tpl_val" -eq 0 ]]; then
        printf '%s' "template"
    elif [[ "${ZBUILD_ROUTER_MAX_TURNS:-}" =~ ^[0-9]+$ ]] && [[ "${ZBUILD_ROUTER_MAX_TURNS}" -eq 0 ]]; then
        printf '%s' "env"
    elif [[ "$_mf_val" =~ ^[0-9]+$ ]] && [[ "$_mf_val" -eq 0 ]]; then
        # #1816: a plugin that declares `max_turns: 0` owns that sentinel. Left
        # unclassified it would be recorded as `default`, which is the one thing
        # it is not — the record would name a source that declared nothing.
        printf '%s' "manifest"
    else
        printf '%s' "default"
    fi
}

# ADR-054 §11 (#1944): per-run wall-clock limit.
# Priority: template max_run_s > ZBUILD_MAX_RUN_S > 20700 s default.
# A non-integer or non-positive value in either source is refused (rc=1).
# Result written to global _RUNNER_MAX_RUN_S.
_runner_resolve_run_limit_s() {
    local _tpl_v="" _env_v=""
    # Template layer — calls template_max_run_s() when available.
    if declare -F template_max_run_s >/dev/null 2>&1; then
        _tpl_v="$(template_max_run_s 2>/dev/null || true)"
    fi
    if [[ -n "$_tpl_v" ]]; then
        if [[ "$_tpl_v" =~ ^[0-9]+$ ]] && [[ "$_tpl_v" -gt 0 ]]; then
            _RUNNER_MAX_RUN_S="$_tpl_v"
            return 0
        else
            printf 'run limit misconfigured: template max_run_s must be a positive integer (got: %s)\n' \
                "$_tpl_v" >&2
            return 1
        fi
    fi
    # Env layer.
    _env_v="${ZBUILD_MAX_RUN_S:-}"
    if [[ -n "$_env_v" ]]; then
        if [[ "$_env_v" =~ ^[0-9]+$ ]] && [[ "$_env_v" -gt 0 ]]; then
            _RUNNER_MAX_RUN_S="$_env_v"
            return 0
        else
            printf 'run limit misconfigured: ZBUILD_MAX_RUN_S must be a positive integer (got: %s)\n' \
                "$_env_v" >&2
            return 1
        fi
    fi
    # Default.
    _RUNNER_MAX_RUN_S=20700
    return 0
}

# ─── zb_call_grace_s_v <var> — #2517 (ADR-063) ──────────────────────────────
# How long a model call may run past its time limit to write its notes and give
# its final reply before it is killed: ZBUILD_CALL_GRACE_S, else 5 minutes. The
# engine cannot tell a call that is stuck from one still thinking: a call still
# running after the grace is killed.
_ZB_CALL_GRACE_DEFAULT=300
zb_call_grace_s_v() {
    local -n _zcg="$1"
    _zcg="${ZBUILD_CALL_GRACE_S:-$_ZB_CALL_GRACE_DEFAULT}"
    [[ "$_zcg" =~ ^[0-9]+$ ]] || _zcg="$_ZB_CALL_GRACE_DEFAULT"
}
