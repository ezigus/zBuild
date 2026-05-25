#!/usr/bin/env bash
# core/output/destinations.sh — Output destination abstraction (issue #213)
# ADR-010 §3. Dispatch table for all output destination kinds.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.
#
# Usage:
#   source "core/output/destinations.sh"
#   emit_output "$content" "$run_id" "$state_dir"
#
# Environment toggles (each destination has an independent on/off):
#   ZBUILD_OUTPUT_STDOUT=0|1          default: 1 (on)
#   ZBUILD_OUTPUT_LOCAL_REPORT=0|1    default: 1 (on)
#   ZBUILD_OUTPUT_GH_COMMENT=0|1     default: on when ZBUILD_ISSUE is set
#   ZBUILD_OUTPUT_GH_CHECK_RUN=0|1   default: 0 (off)
#   ZBUILD_OUTPUT_STEP_SUMMARY=0|1   default: on when GITHUB_STEP_SUMMARY is set

[[ -n "${_ZBUILD_OUTPUT_DESTINATIONS_LOADED:-}" ]] && return 0
_ZBUILD_OUTPUT_DESTINATIONS_LOADED=1

# ─── stdout destination ───────────────────────────────────────────────────────
# On by default; disabled by ZBUILD_OUTPUT_STDOUT=0.
_dest_stdout() {
    local content="$1"
    local toggle="${ZBUILD_OUTPUT_STDOUT:-1}"
    [[ "$toggle" == "0" ]] && return 0
    printf '%s\n' "$content"
}

# ─── local-report destination ─────────────────────────────────────────────────
# Writes state_dir/report-<run_id>.md. On by default; disabled by
# ZBUILD_OUTPUT_LOCAL_REPORT=0.
_dest_local_report() {
    local content="$1"
    local run_id="$2"
    local state_dir="$3"
    local toggle="${ZBUILD_OUTPUT_LOCAL_REPORT:-1}"
    [[ "$toggle" == "0" ]] && return 0
    local report_path="$state_dir/report-${run_id}.md"
    printf '%s\n' "$content" | atomic_write "$report_path"
}

# ─── gh-pr-comment destination ────────────────────────────────────────────────
# Posts to GitHub issue/PR as a comment using gh CLI.
# Active when ZBUILD_ISSUE is set (and not "0") AND ZBUILD_OUTPUT_GH_COMMENT != 0.
_dest_gh_comment() {
    local content="$1"
    local run_id="$2"
    local state_dir="$3"

    if [[ -z "${ZBUILD_ISSUE:-}" || "${ZBUILD_ISSUE}" == "0" ]]; then
        return 0
    fi

    local toggle="${ZBUILD_OUTPUT_GH_COMMENT:-1}"
    [[ "$toggle" == "0" ]] && return 0

    gh issue comment "$ZBUILD_ISSUE" --body "$content"
}

# ─── gh-check-run destination ─────────────────────────────────────────────────
# Posts output as a GitHub check-run annotation. Off by default;
# enabled by ZBUILD_OUTPUT_GH_CHECK_RUN=1.
_dest_gh_check_run() {
    local content="$1"
    local run_id="$2"
    local toggle="${ZBUILD_OUTPUT_GH_CHECK_RUN:-0}"
    [[ "$toggle" != "1" ]] && return 0

    gh api \
        --method POST \
        -H "Accept: application/vnd.github+json" \
        repos/"${GITHUB_REPOSITORY:-}"/check-runs \
        -f name="zBuild" \
        -f head_sha="${GITHUB_SHA:-}" \
        -f status="completed" \
        -f conclusion="neutral" \
        -f "output[title]=zBuild Report (run ${run_id})" \
        -f "output[summary]=${content}" \
        >/dev/null 2>&1
}

# ─── step-summary destination ─────────────────────────────────────────────────
# Appends content to $GITHUB_STEP_SUMMARY.
# Active when GITHUB_STEP_SUMMARY is set AND ZBUILD_OUTPUT_STEP_SUMMARY != 0.
_dest_step_summary() {
    local content="$1"

    if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
        return 0
    fi

    local toggle="${ZBUILD_OUTPUT_STEP_SUMMARY:-1}"
    [[ "$toggle" == "0" ]] && return 0

    printf '%s\n' "$content" >> "$GITHUB_STEP_SUMMARY"
}

# ─── Main dispatch ────────────────────────────────────────────────────────────
# emit_output <content> <run_id> <state_dir>
# Dispatches to all enabled destinations. Returns non-zero if any
# destination that is critical (gh-comment) fails.
emit_output() {
    local content="$1"
    local run_id="${2:-unknown}"
    local state_dir="${3:-.}"

    local rc=0

    _dest_stdout       "$content" "$run_id" "$state_dir" || rc=$?
    _dest_local_report "$content" "$run_id" "$state_dir" || rc=$?
    _dest_gh_comment   "$content" "$run_id" "$state_dir" || rc=$?
    _dest_gh_check_run "$content" "$run_id" "$state_dir" || rc=$?
    _dest_step_summary "$content" "$run_id" "$state_dir" || rc=$?

    return $rc
}
