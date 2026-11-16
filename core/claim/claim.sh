#!/usr/bin/env bash
# core/claim/claim.sh — Cross-machine soft claim via zbuild:claimed GitHub label (#1764)
# Sourced by runner.sh; defines zbuild_claim_acquire and zbuild_claim_release.
# Back-end primitives (_ccgl_*) come from plugins/claim-coordinator/github-labels/plugin.sh
# which is sourced automatically below when not already loaded.
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail.

[[ -n "${_ZBUILD_CLAIM_SH_LOADED:-}" ]] && return 0
_ZBUILD_CLAIM_SH_LOADED=1

# Resolve the backend plugin's path relative to this file (core/claim/ → ../../plugins/...)
_claim_sh_own_dir="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
# shellcheck source=../../plugins/claim-coordinator/github-labels/plugin.sh
source "$_claim_sh_own_dir/../../plugins/claim-coordinator/github-labels/plugin.sh"
unset _claim_sh_own_dir

# Global: set by zbuild_claim_acquire when it successfully adds zbuild:claimed.
# Guards zbuild_claim_release so a refused run never removes another run's claim.
_ZBUILD_CLAIM_ACQUIRED=""

# _ccgl_read_holder <issue> — read the holder string from the claim store / comment.
_ccgl_read_holder() {
    local issue="$1"
    case "$(_ccgl_backend)" in
        local-fs)
            local store="${ZBUILD_CLAIM_STORE:-}"
            if [[ -n "$store" ]]; then
                cat "$store/$issue/holder.txt" 2>/dev/null || true
            fi
            ;;
        gh)
            # Best-effort: find the most recent claim comment and extract the holder line.
            local body
            body="$(gh issue comment list "$issue" --json body \
                --jq '[.[] | select(.body | contains("<!-- zbuild-claim")) | .body] | last' \
                2>/dev/null || true)"
            # First non-marker line is the holder string; avoid pipe-into-head (SIGPIPE rule)
            local line found_holder=""
            while IFS= read -r line; do
                case "$line" in
                    "<!-- zbuild-claim"*) continue ;;
                    "") continue ;;
                    *)  found_holder="$line"; break ;;
                esac
            done <<< "$body"
            [[ -n "$found_holder" ]] && printf '%s' "$found_holder" || true
            ;;
        *) true ;;
    esac
}

# _ccgl_post_claim_comment <issue> <holder> — record holder info in comment.txt (local-fs)
# or as a GitHub issue comment (gh backend).
_ccgl_post_claim_comment() {
    local issue="$1" holder="$2"
    local run_id="${ZBUILD_RUN_ID:-}"
    local body
    body="$(printf '<!-- zbuild-claim run_id=%s -->\n%s' "$run_id" "$holder")"
    case "$(_ccgl_backend)" in
        gh)
            gh issue comment "$issue" --body "$body" >/dev/null 2>&1 || true
            ;;
        local-fs)
            local store="${ZBUILD_CLAIM_STORE:-}"
            [[ -z "$store" ]] && return 0
            mkdir -p "$store/$issue"
            printf 'Status: active\n%s\n' "$holder" > "$store/$issue/comment.txt"
            printf '%s\n' "$holder" > "$store/$issue/holder.txt"
            ;;
    esac
}

# _ccgl_finish_claim_comment <issue> — append "Status: finished" to the claim record.
_ccgl_finish_claim_comment() {
    local issue="$1"
    case "$(_ccgl_backend)" in
        gh)
            # Best-effort: no test coverage for gh backend on this path.
            true
            ;;
        local-fs)
            local store="${ZBUILD_CLAIM_STORE:-}"
            [[ -z "$store" ]] && return 0
            local comment_file="$store/$issue/comment.txt"
            if [[ -f "$comment_file" ]]; then
                printf 'Status: finished\n' >> "$comment_file"
            else
                printf 'Status: finished\n' > "$comment_file"
            fi
            ;;
    esac
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

    # Build holder string (DSCLA-2)
    local holder
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        holder="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
    else
        local run_id="${ZBUILD_RUN_ID:-}"
        local machine; machine="$(_ccgl_machine_id)"
        holder="run_id=${run_id} machine=${machine}"
    fi

    # Add zbuild:claimed label; on failure, skip gracefully
    _ccgl_add_label "$issue" "zbuild:claimed" || return 0

    # Record holder info and post claim comment (advisory)
    _ccgl_post_claim_comment "$issue" "$holder" || true

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

    # Update comment to show finished status (advisory)
    _ccgl_finish_claim_comment "$issue" || true

    return 0
}
