#!/usr/bin/env bash
# plugins/claim-coordinator/github-labels/plugin.sh — ADR-005 default plugin (#308)
# Uses zbuild:claimed as the single shared cross-machine claim label (#1764).
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail.

[[ -n "${_ZBUILD_CLAIM_GH_LABELS_LOADED:-}" ]] && return 0
_ZBUILD_CLAIM_GH_LABELS_LOADED=1

# ─── Backend selection ────────────────────────────────────────────────────────
# Prod uses `gh issue` (ZBUILD_CLAIM_BACKEND=gh, the default).
# Tests use a local filesystem store (ZBUILD_CLAIM_BACKEND=local-fs) at
# ZBUILD_CLAIM_STORE/<issue>/labels.txt — one label per line, file-locked via
# flock to model gh's atomic label edits within a single machine.
_ccgl_backend() { echo "${ZBUILD_CLAIM_BACKEND:-gh}"; }

# Bounded flock wait (seconds) — never block forever on a stale lock. Matches
# the bounded-wait pattern used elsewhere in the repo (#320 review L60/L83).
_ccgl_flock_timeout_sec() { echo "${ZBUILD_CLAIM_FLOCK_TIMEOUT_SEC:-5}"; }

# Local-fs helpers (test backend) ─────────────────────────────────────────────
_ccgl_lf_labels_file() {
    local issue="$1"
    local store="${ZBUILD_CLAIM_STORE:?ZBUILD_CLAIM_STORE must be set for local-fs backend}"
    mkdir -p "$store/$issue"
    echo "$store/$issue/labels.txt"
}

# Read labels for an issue (one per line).
# Exit 0 with output on success (empty output = no labels OR file absent).
# Exit 1 on backend ERROR (caller must propagate — #320 review L46).
_ccgl_read_labels() {
    local issue="$1"
    case "$(_ccgl_backend)" in
        gh)
            # gh failure is a backend error (auth/rate-limit/network).
            # Distinguish "issue has no labels" (rc=0, empty output) from
            # "gh failed" (rc!=0) — only the latter is an error.
            local out
            if ! out="$(gh issue view "$issue" --json labels --jq '.labels[].name' 2>/dev/null)"; then
                return 1
            fi
            printf '%s' "$out"
            return 0
            ;;
        local-fs)
            local f; f="$(_ccgl_lf_labels_file "$issue")"
            if [[ -f "$f" ]]; then
                cat "$f"
            fi
            return 0
            ;;
        *) return 1 ;;
    esac
}

# Atomically add a label to an issue.
_ccgl_add_label() {
    local issue="$1" label="$2"
    case "$(_ccgl_backend)" in
        gh)
            gh issue edit "$issue" --add-label "$label" >/dev/null 2>&1
            ;;
        local-fs)
            local f; f="$(_ccgl_lf_labels_file "$issue")"
            local timeout; timeout="$(_ccgl_flock_timeout_sec)"
            # Exit 0 when label is freshly added; exit 2 when already present
            # (lets callers detect a lost race inside the same lock — no TOCTOU).
            (
                exec 9>"${f}.lock"
                # Bounded wait — flock -w returns non-zero on timeout so we
                # surface the failure instead of hanging the pipeline.
                flock -w "$timeout" 9 || exit 1
                touch "$f"
                if grep -Fxq "$label" "$f"; then
                    exit 2
                fi
                echo "$label" >> "$f"
                exit 0
            )
            ;;
        *) return 1 ;;
    esac
}

# Atomically remove a label from an issue.
_ccgl_remove_label() {
    local issue="$1" label="$2"
    case "$(_ccgl_backend)" in
        gh)
            gh issue edit "$issue" --remove-label "$label" >/dev/null 2>&1
            ;;
        local-fs)
            local f; f="$(_ccgl_lf_labels_file "$issue")"
            [[ ! -f "$f" ]] && return 0
            local timeout; timeout="$(_ccgl_flock_timeout_sec)"
            (
                exec 9>"${f}.lock"
                flock -w "$timeout" 9 || exit 1
                grep -Fxv "$label" "$f" > "${f}.new" || true
                mv "${f}.new" "$f"
            )
            ;;
        *) return 1 ;;
    esac
}

# _ccgl_read_holder <issue> — extract the holder string from the run-status comment.
# The holder is embedded by rsc_render_header as <!-- zbuild-holder: <string> -->.
_ccgl_read_holder() {
    local issue="$1"
    case "${ZBUILD_CLAIM_BACKEND:-gh}" in
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
            # Get authenticated actor; fall back to GITHUB_ACTOR env var.
            # Must filter by actor: a spoofed comment from another user must not
            # displace the holder string (DSCLA-23 security requirement).
            local actor=""
            actor="$(gh api user --jq .login 2>/dev/null || true)"
            [[ -z "$actor" ]] && actor="${GITHUB_ACTOR:-}"

            # Resolve repo slug from GITHUB_REPOSITORY or zbuild_repo_slug helper.
            local repo="${GITHUB_REPOSITORY:-}"
            if [[ -z "$repo" ]] && declare -F zbuild_repo_slug >/dev/null 2>&1; then
                repo="$(zbuild_repo_slug 2>/dev/null || true)"
            fi

            local body=""
            if [[ -n "$repo" && -n "$actor" ]]; then
                # Fetch comments with author info; keep only the authenticated actor's.
                local all_comments=""
                all_comments="$(gh api "repos/$repo/issues/$issue/comments" 2>/dev/null || true)"
                if [[ -n "$all_comments" ]]; then
                    body="$(jq -r --arg actor "$actor" \
                        '[.[] | select(.user.login == $actor) | select(.body | contains("<!-- zbuild-run-status")) | .body] | last // empty' \
                        <<< "$all_comments" 2>/dev/null || true)"
                fi
            fi
            if [[ -z "$body" ]]; then
                # Graceful fallback: list without author filtering.
                body="$(gh issue comment list "$issue" --json body \
                    --jq '[.[] | select(.body | contains("<!-- zbuild-run-status")) | .body] | last' \
                    2>/dev/null || true)"
            fi

            local line
            while IFS= read -r line; do
                if [[ "$line" =~ ^'<!-- zbuild-holder: '(.+)' -->'$ ]]; then
                    printf '%s' "${BASH_REMATCH[1]}"
                    return 0
                fi
            done <<< "$body"
            ;;
        *) ;;
    esac
}

# ─── Hook: claim <issue_id> ───────────────────────────────────────────────────
# stdout: {"acquired": true} on success
#         {"acquired": false, "holder": "<holder>"} when zbuild:claimed is already present
# Exit codes:
#   0 — claim attempted (read JSON for acquired=true|false)
#   1 — backend error
#   2 — usage error (missing issue id)
claim_coordinator_claim() {
    local issue="$1"
    [[ -z "$issue" ]] && { printf 'claim_coordinator_claim: missing issue id\n' >&2 || true; return 2; }

    # Read current labels; propagate backend failure.
    local existing=""
    if ! existing="$(_ccgl_read_labels "$issue")"; then
        printf '{"acquired": false, "reason": "backend_read_error"}\n'
        return 1
    fi

    # If zbuild:claimed is already present, another run holds it.
    if grep -Fxq "zbuild:claimed" <<< "$existing" 2>/dev/null; then
        local holder=""
        holder="$(_ccgl_read_holder "$issue" || true)"
        # Escape quotes for valid JSON.
        local escaped_holder
        escaped_holder="$(printf '%s' "$holder" | sed 's/\\/\\\\/g; s/"/\\"/g' || true)"
        printf '{"acquired": false, "holder": "%s"}\n' "$escaped_holder"
        return 0
    fi

    # Add the shared claim label zbuild:claimed (no hostname component — RQLAB-2).
    # For local-fs: _ccgl_add_label exits 2 when the label was already present
    # (atomic check inside the lock — catches races in the window above).
    local add_rc=0
    _ccgl_add_label "$issue" "zbuild:claimed" || add_rc=$?
    if [[ "$add_rc" -eq 2 ]]; then
        # Lost the race: another claimant added zbuild:claimed in the window.
        local holder=""
        holder="$(_ccgl_read_holder "$issue" || true)"
        local escaped_holder
        escaped_holder="$(printf '%s' "$holder" | sed 's/\\/\\\\/g; s/"/\\"/g' || true)"
        printf '{"acquired": false, "holder": "%s"}\n' "$escaped_holder"
        return 0
    fi
    if [[ "$add_rc" -ne 0 ]]; then
        printf '{"acquired": false, "reason": "backend_error"}\n'
        return 1
    fi

    printf '{"acquired": true}\n'
    return 0
}

# ─── Hook: release <issue_id> ─────────────────────────────────────────────────
claim_coordinator_release() {
    local issue="$1"
    [[ -z "$issue" ]] && { printf 'claim_coordinator_release: missing issue id\n' >&2 || true; return 2; }
    _ccgl_remove_label "$issue" "zbuild:claimed"
}

# ─── Hook: heartbeat <lease_id> ───────────────────────────────────────────────
# Labels don't expire — exit 0 always. Provided so the contract is satisfied.
claim_coordinator_heartbeat() {
    return 0
}

# ─── Hook: list_claims ────────────────────────────────────────────────────────
# stdout: JSON array of {issue, holder, acquired_at}.
# Exit 0 on success (with [] for empty); exit 1 on backend error (#320 L192).
claim_coordinator_list_claims() {
    case "$(_ccgl_backend)" in
        gh)
            # List all issues with the zbuild:claimed label.
            local issues_json
            if ! issues_json="$(gh issue list --label "zbuild:claimed" --json number 2>/dev/null)"; then
                printf 'list_claims: gh issue list failed\n' >&2 || true
                return 1
            fi
            local results='[]'
            results="$(printf '%s' "$issues_json" \
                | jq 'map({issue: .number, holder: "unknown", acquired_at: null})' \
                2>/dev/null || true)"
            printf '%s\n' "${results:-[]}"
            ;;
        local-fs)
            local store="${ZBUILD_CLAIM_STORE:?}"
            local results='[]'
            local issue_dir issue holder
            for issue_dir in "$store"/*/; do
                [[ -d "$issue_dir" ]] || continue
                issue="$(basename "$issue_dir")"
                [[ -f "$issue_dir/labels.txt" ]] || continue
                grep -Fxq "zbuild:claimed" "$issue_dir/labels.txt" 2>/dev/null || continue
                holder="$(_ccgl_read_holder "$issue" || true)"
                results="$(printf '%s' "$results" | jq --arg i "$issue" --arg h "$holder" \
                    '. + [{issue: ($i|tonumber), holder: $h, acquired_at: null}]')"
            done
            printf '%s\n' "$results"
            ;;
        *) printf '[]\n' ;;
    esac
    return 0
}
