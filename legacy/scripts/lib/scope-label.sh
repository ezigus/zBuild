#!/usr/bin/env bash
# scope-label.sh — Standalone scope_label function for sw-loop.sh and pipeline-state.sh
# Sourced by pipeline-state.sh and (independently) by sw-loop.sh.
# Bash 3.2 compatible: no declare -A, no readarray, no ${var,,} / ${var^^}.
[[ -n "${_SCOPE_LABEL_LOADED:-}" ]] && return 0
_SCOPE_LABEL_LOADED=1

VERSION="3.6.1"

# Default values for variables read by scope_label.
# These are no-ops when the caller already has the variables set.
OUTER_STAGE="${OUTER_STAGE:-}"
COMPOUND_QUALITY_CYCLE="${COMPOUND_QUALITY_CYCLE:-}"
INNER_STAGE="${INNER_STAGE:-}"
SELF_HEAL_COUNT="${SELF_HEAL_COUNT:-0}"

# Read OUTER_STAGE, OUTER_STAGE_START_COMMIT, INNER_STAGE from the pipeline
# state file. Only sets a variable if it is currently empty (env takes
# precedence). No-op when the state file is absent.
_read_scope_state() {
    local _sf="${PROJECT_ROOT:-.}/.claude/pipeline-state.md"
    [[ -f "$_sf" ]] || return 0
    local _in_fm=false _line _v
    while IFS= read -r _line; do
        if [[ "$_line" == "---" ]]; then
            if $_in_fm; then break; else _in_fm=true; continue; fi
        fi
        $_in_fm || continue
        case "$_line" in
            outer_stage:*)
                _v="${_line#outer_stage:}"; _v="${_v# }"
                [[ -z "${OUTER_STAGE:-}" && -n "$_v" ]] && OUTER_STAGE="$_v" ;;
            outer_stage_start_commit:*)
                _v="${_line#outer_stage_start_commit:}"; _v="${_v# }"
                [[ -z "${OUTER_STAGE_START_COMMIT:-}" && -n "$_v" ]] && OUTER_STAGE_START_COMMIT="$_v" ;;
            inner_stage:*)
                _v="${_line#inner_stage:}"; _v="${_v# }"
                [[ -z "${INNER_STAGE:-}" && -n "$_v" ]] && INNER_STAGE="$_v" ;;
        esac
    done < "$_sf"
}

# Returns a human-readable label for the current execution scope.
# Inner defaults to "Build" when INNER_STAGE is unset.
# Outer prefix is omitted when OUTER_STAGE is unset.
# Examples:
#   Top-level:               "Build Iteration 3"
#   Inside compound_quality: "Compound Quality 2 — Build Iteration 3"
scope_label() {
    local outer="${OUTER_STAGE:-}"
    local inner="${INNER_STAGE:-}"
    # Bash 3.2 compat: use awk for capitalization instead of ${var^}
    local build_iter
    if (( ${ITERATION:-0} > 0 )); then
        build_iter="${ITERATION}"
    else
        build_iter=$(( ${SELF_HEAL_COUNT:-0} + 1 ))
    fi
    local cq_cycle="${COMPOUND_QUALITY_CYCLE:-1}"

    local inner_pretty
    inner_pretty=$(echo "${inner:-build}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')

    if [[ -n "$outer" ]]; then
        local outer_pretty
        outer_pretty=$(echo "$outer" | tr '_' ' ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)}} 1')
        echo "${outer_pretty} ${cq_cycle} — ${inner_pretty} Iteration ${build_iter}"
    else
        echo "${inner_pretty} Iteration ${build_iter}"
    fi
}
