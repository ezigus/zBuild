#!/usr/bin/env bash
# plugins/agent/plan/lib/entry.sh — plan's stage entry (#1835): the signal
# guard, inputs from the engine's index, the engine's artifact dir, and the
# result writer. Split out of plugin.sh (review #2237: the plugin is over the
# 500-line guide). Sourced by plugin.sh; uses _plan_run_inner from there.

[[ -n "${_ZBUILD_PLAN_ENTRY_LOADED:-}" ]] && return 0
_ZBUILD_PLAN_ENTRY_LOADED=1

# _plan_write_outcome <out-path> <outcome> <reason>
# Writes a result with no plan in it — the failure paths — through the one
# writer (#2366: one outcome from the engine's list).
_plan_write_outcome() {
    local _out="$1" _outcome="$2" _reason="$3"
    [[ -z "$_out" ]] && return 0
    # A result that cannot be written is reported, never skipped: a stage with
    # no result reads as one that explained nothing (#1837's rule, here too).
    if stage_result_write "$_out" "$_outcome" "$_reason"; then
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
        _plan_write_outcome "${ZBUILD_ARTIFACT_DIR}/plan.json" \
            "${1:-$STAGE_SIGNAL_DISPOSITION}" "${2:-$STAGE_SIGNAL_REASON}" || true
    fi
    exit 1
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

    # #2364: the scope manifest and the issue text, found by what they are among
    # every earlier output. The issue text is required; the scope manifest is
    # the router's to enforce (ADR-043).
    local scope_manifest goal_text=""
    scope_manifest="$(earlier_scope_manifest "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    goal_text="$(earlier_issue_text "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"
    if [[ -z "$goal_text" ]]; then
        error "plan_run: no earlier output carries the issue text"
        _plan_write_outcome "${artifacts_dir}/plan.json" "broken" "intake_goal_missing"
        return 1
    fi

    _plan_run_inner \
        "$scope_manifest" \
        "$goal_text" \
        "$artifacts_dir/plan.json" \
        "$artifacts_dir"
}
