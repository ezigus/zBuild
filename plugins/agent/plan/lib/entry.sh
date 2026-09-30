#!/usr/bin/env bash
# plugins/agent/plan/lib/entry.sh — plan's stage entry (#1835): the signal
# guard, inputs from the engine's index, the engine's artifact dir, and the v2
# result writer. Split out of plugin.sh (review #2237: the plugin is over the
# 500-line guide). Sourced by plugin.sh; uses _plan_run_inner from there.

[[ -n "${_ZBUILD_PLAN_ENTRY_LOADED:-}" ]] && return 0
_ZBUILD_PLAN_ENTRY_LOADED=1

# _plan_write_result <out-path> <verdict> <disposition> <reason>
# Writes a minimal v2 result JSON to <out-path> via atomic_write.
# Used by failure paths that have no plan content yet.
_plan_write_result() {
    local _out="$1" _verdict="$2" _disposition="$3" _reason="$4" _json
    [[ -z "$_out" ]] && return 0
    # A result that cannot be written is reported, never skipped: a stage with
    # no result reads as one that explained nothing (#1837's rule, here too).
    if _json="$(jq -nc --arg v "$_verdict" --arg d "$_disposition" --arg r "$_reason" \
            '{result_contract:2,verdict:$v,disposition:$d,reason:$r}')" \
        && atomic_write "$_out" <<< "$_json"; then
        _PLAN_RESULT_WRITTEN=1
        return 0
    fi
    error "plan: could not write $_out"
    return 1
}

# ─── run ────────────────────────────────────────────────────────────────────
# Hook called by the pipeline runner: plan_run(stage, state_file)
# Inputs come from the engine's index and the result goes to the engine's
# artifact dir (#1835); nothing is derived from the state file.
plan_run() {
    # The signal guard spans the whole stage and is ended on every return, so
    # the caller's own TERM/INT handlers come back (#2225 stage-signal).
    stage_signal_begin _plan_on_signal || return 1
    local rc=0
    _plan_run_entry "$@" || rc=$?
    stage_signal_end
    return "$rc"
}

# An outside signal ends the stage: record it with the one word for it (#1835:
# "every exit path — success, failure, and interruption"). A result already
# written stands.
_plan_on_signal() {
    if [[ -n "${ZBUILD_ARTIFACT_DIR:-}" && -z "${_PLAN_RESULT_WRITTEN:-}" ]]; then
        _plan_write_result "${ZBUILD_ARTIFACT_DIR}/plan.json" "error" \
            "${1:-$STAGE_SIGNAL_DISPOSITION}" "${2:-$STAGE_SIGNAL_REASON}" || true
    fi
    exit 1
}

# _plan_input <id> — the path the engine resolved for input <id>, from its
# index (ZBUILD_STAGE_INPUTS). Empty when the engine named none. Nothing is
# guessed: no environment variable, no path derived from the state file (#1835).
_plan_input() {
    [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -f "${ZBUILD_STAGE_INPUTS:-}" ]] || return 0
    jq -r --arg id "$1" '.inputs[$id] // empty' "$ZBUILD_STAGE_INPUTS" 2>/dev/null || true
}

_plan_run_entry() {
    _PLAN_RESULT_WRITTEN=""
    # The engine names the artifact dir (core/plugin-registry/lifecycle.sh); plan
    # does not derive one from its state file.
    local artifacts_dir="${ZBUILD_ARTIFACT_DIR:-}"
    if [[ -z "$artifacts_dir" ]]; then
        error "plan_run: ZBUILD_ARTIFACT_DIR is not set — the engine gave plan nowhere to write plan.json"
        return 1
    fi
    mkdir -p "$artifacts_dir"

    # Both inputs come from the engine's index, or the stage cannot run: a
    # missing one is the engine's contract broken, not a goal to go looking for.
    local scope_manifest goal_path goal_text=""
    scope_manifest="$(_plan_input scope_manifest)"
    goal_path="$(_plan_input intake_goal)"
    if [[ -z "$scope_manifest" || -z "$goal_path" ]]; then
        local _missing=""
        [[ -z "$scope_manifest" ]] && _missing="scope_manifest"
        [[ -z "$goal_path" ]] && _missing="${_missing:+$_missing, }intake_goal"
        error "plan_run: the engine's input index (ZBUILD_STAGE_INPUTS) names no $_missing"
        _plan_write_result "${artifacts_dir}/plan.json" "error" "broken" "input_missing"
        return 1
    fi
    if [[ ! -f "$goal_path" ]]; then
        error "plan_run: intake_goal path unreadable: $goal_path"
        _plan_write_result "${artifacts_dir}/plan.json" "error" "broken" "intake_goal_path_unreadable"
        return 1
    fi
    goal_text="$(cat "$goal_path")"
    if [[ -z "$goal_text" ]]; then
        error "plan_run: intake_goal is empty: $goal_path"
        _plan_write_result "${artifacts_dir}/plan.json" "error" "broken" "intake_goal_missing"
        return 1
    fi

    _plan_run_inner \
        "$scope_manifest" \
        "$goal_text" \
        "$artifacts_dir/plan.json" \
        "$artifacts_dir"
}
