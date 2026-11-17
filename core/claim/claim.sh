#!/usr/bin/env bash
# core/claim/claim.sh — Cross-machine soft claim via zbuild:claimed GitHub label (#1764)
# Sourced by runner.sh; defines zbuild_claim_acquire and zbuild_claim_release.
# Back-end primitives (_ccgl_*) come from plugins/claim-coordinator/github-labels/plugin.sh
# which is sourced automatically below when not already loaded.
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail.

[[ -n "${_ZBUILD_CLAIM_SH_LOADED:-}" ]] && return 0
_ZBUILD_CLAIM_SH_LOADED=1

# Use $_ZBUILD_ROOT (set by runner.sh before sourcing claim.sh) — no $(cd ...) fork on load path
# shellcheck source=../../plugins/claim-coordinator/github-labels/plugin.sh
source "$_ZBUILD_ROOT/plugins/claim-coordinator/github-labels/plugin.sh"

# Global: set by zbuild_claim_acquire when it successfully adds zbuild:claimed.
# Guards zbuild_claim_release so a refused run never removes another run's claim.
_ZBUILD_CLAIM_ACQUIRED=""

# _ccgl_read_holder <issue> — read the holder string from the run-status comment.
# The holder is embedded by rsc_render_header as <!-- zbuild-holder: <string> -->.
_ccgl_read_holder() {
    local issue="$1"
    case "$(_ccgl_backend)" in
        local-fs)
            local store="${ZBUILD_CLAIM_STORE:-}"
            if [[ -n "$store" ]]; then
                local rsc="$store/$issue/run-status-comment.txt"
                if [[ -f "$rsc" ]]; then
                    local line
                    while IFS= read -r line; do
                        if [[ "$line" =~ ^'<!-- zbuild-holder: '(.+)' -->'$ ]]; then
                            printf '%s' "${BASH_REMATCH[1]}"
                            return 0
                        fi
                    done < "$rsc"
                fi
            fi
            ;;
        gh)
            # Best-effort: find the most recent run-status comment and extract <!-- zbuild-holder: -->.
            local body
            body="$(gh issue comment list "$issue" --json body \
                --jq '[.[] | select(.body | contains("<!-- zbuild-run-status")) | .body] | last' \
                2>/dev/null || true)"
            local line
            while IFS= read -r line; do
                if [[ "$line" =~ ^'<!-- zbuild-holder: '(.+)' -->'$ ]]; then
                    printf '%s' "${BASH_REMATCH[1]}"
                    return 0
                fi
            done <<< "$body"
            true
            ;;
        *) true ;;
    esac
}


# zbuild_claim_build_holder — set and export _ZBUILD_CLAIM_HOLDER for this run.
# Must be called before the run-status sidecar is spawned (see runner.sh) so the
# sidecar inherits the holder string via its environment and rsc_render_header can
# embed it in <!-- zbuild-holder: --> (ADR-005 §2 / #1764).
# zbuild_claim_acquire calls this automatically on the success path.
zbuild_claim_build_holder() {
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        _ZBUILD_CLAIM_HOLDER="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
    else
        local run_id="${ZBUILD_RUN_ID:-}"
        # ${ZBUILD_CLAIM_MACHINE_ID:-${HOSTNAME}}: ZBUILD_CLAIM_MACHINE_ID overrides for tests;
        # ${HOSTNAME} is a bash built-in — no external hostname command, no fork (ADR-005 §2)
        _ZBUILD_CLAIM_HOLDER="run_id=${run_id} machine=${ZBUILD_CLAIM_MACHINE_ID:-${HOSTNAME}}"
    fi
    export _ZBUILD_CLAIM_HOLDER
}

# zbuild_claim_acquire <issue> — acquire the cross-machine claim for <issue>.
#
# Sets _ZBUILD_CLAIM_HOLDER (global) and returns:
#   0 — claim acquired, or skipped (no issue / graceful degradation)
#   1 — refused: zbuild:claimed is already on the issue
#
# Graceful degradation: backend errors return 0 (the local flock still serialises
# same-machine runs). Logs the skip to the run's state dir but never fails the run.
zbuild_claim_acquire() {
    local issue="$1"
    _ZBUILD_CLAIM_HOLDER=""

    # Empty issue or goal-only run (issue=0) → no-op (DSCLA-8)
    [[ -z "$issue" || "$issue" == "0" ]] && return 0

    # Read current labels; on backend error, skip gracefully
    local existing
    if ! existing="$(_ccgl_read_labels "$issue")"; then
        return 0
    fi

    # Check if zbuild:claimed is already present (DSCLA-3, DSCLA-4)
    if grep -Fxq "zbuild:claimed" <<< "$existing" 2>/dev/null; then
        _ZBUILD_CLAIM_HOLDER="$(_ccgl_read_holder "$issue")"
        return 1
    fi

    # Build and export holder string (DSCLA-2 / ADR-005 §2).
    # zbuild_claim_build_holder is also called in runner.sh before the sidecar
    # spawn so the sidecar inherits _ZBUILD_CLAIM_HOLDER; calling it again here
    # keeps the in-process value consistent after the acquire.
    zbuild_claim_build_holder

    # Add zbuild:claimed label; on failure, skip gracefully
    _ccgl_add_label "$issue" "zbuild:claimed" || return 0

    _ZBUILD_CLAIM_ACQUIRED="1"
    return 0
}

# zbuild_claim_release <issue> — release the cross-machine claim (advisory).
# Removes zbuild:claimed and marks the comment finished.
# No-op when the claim was never acquired (guards against releasing another run's claim).
zbuild_claim_release() {
    local issue="$1"

    [[ -z "$issue" || "$issue" == "0" ]] && return 0

    # Only release if this process acquired the claim
    [[ -z "${_ZBUILD_CLAIM_ACQUIRED:-}" ]] && return 0

    # Remove zbuild:claimed (advisory; failures never abort the run)
    _ccgl_remove_label "$issue" "zbuild:claimed" || true

    return 0
}
