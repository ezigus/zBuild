#!/usr/bin/env bash
# plugins/claim-coordinator/github-labels/plugin.sh — ADR-005 default plugin (#308)
# Ports legacy/scripts/lib/daemon-state.sh:602-720 to the plugin contract.
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail.

[[ -n "${_ZBUILD_CLAIM_GH_LABELS_LOADED:-}" ]] && return 0
_ZBUILD_CLAIM_GH_LABELS_LOADED=1

# ─── Backend selection ────────────────────────────────────────────────────────
# Prod uses `gh issue` (ZBUILD_CLAIM_BACKEND=gh, the default).
# Tests use a local filesystem store (ZBUILD_CLAIM_BACKEND=local-fs) at
# ZBUILD_CLAIM_STORE/<issue>/labels.txt — one label per line, file-locked via
# flock to model gh's atomic label edits within a single machine.
_ccgl_backend() { echo "${ZBUILD_CLAIM_BACKEND:-gh}"; }
_ccgl_machine_id() {
    local m="${ZBUILD_CLAIM_MACHINE_ID:-}"
    [[ -n "$m" ]] && { echo "$m"; return; }
    if command -v hostname >/dev/null 2>&1; then
        hostname
    else
        echo "unknown-host"
    fi
}

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
            (
                exec 9>"${f}.lock"
                # Bounded wait — flock -w returns non-zero on timeout so we
                # surface the failure instead of hanging the pipeline.
                flock -w "$timeout" 9 || exit 1
                touch "$f"
                if ! grep -Fxq "$label" "$f"; then
                    echo "$label" >> "$f"
                fi
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

# ─── Hook: claim <issue_id> ───────────────────────────────────────────────────
# stdout: {"acquired": bool, "lease_id": "<machine>:<issue>"}
# Exit codes:
#   0 — claim attempted (read JSON for acquired=true|false)
#   1 — backend error (caller must NOT proceed; treat issue as undeterminable)
#   2 — usage error (missing issue id)
claim_coordinator_claim() {
    local issue="$1"
    [[ -z "$issue" ]] && { error "claim_coordinator_claim: missing issue id" >&2 || true; return 2; }

    local machine; machine="$(_ccgl_machine_id)"
    local our_label="claimed:${machine}"
    local lease_id="${machine}:${issue}"

    # Phase 1: read current labels. Propagate backend failure (#320 L134).
    local existing
    if ! existing="$(_ccgl_read_labels "$issue")"; then
        printf '{"acquired": false, "lease_id": "%s", "reason": "backend_read_error"}\n' "$lease_id"
        return 1
    fi
    if grep -q "^claimed:" <<< "$existing" && ! grep -Fxq "$our_label" <<< "$existing"; then
        printf '{"acquired": false, "lease_id": "%s", "reason": "already_claimed"}\n' "$lease_id"
        return 0
    fi

    # Phase 2: add our label.
    _ccgl_add_label "$issue" "$our_label" || {
        printf '{"acquired": false, "lease_id": "%s", "reason": "backend_error"}\n' "$lease_id"
        return 1
    }

    # Phase 3: random backoff (legacy: 300–1100 ms) before re-verifying.
    local min_ms="${ZBUILD_CLAIM_BACKOFF_MIN_MS:-300}"
    local max_ms="${ZBUILD_CLAIM_BACKOFF_MAX_MS:-1100}"
    local span=$(( max_ms - min_ms ))
    local sleep_ms=$(( min_ms + (RANDOM % (span > 0 ? span : 1)) ))
    # Convert ms → fractional seconds for sleep; macOS / GNU sleep both accept decimals.
    sleep "$(awk -v n="$sleep_ms" 'BEGIN{printf "%.3f", n/1000.0}')"

    # Phase 4: re-read and verify EXCLUSIVITY — exactly one claimed:* label
    # and it MUST be ours (legacy daemon-state.sh:680-700 semantics, #320
    # review L163). If our label is missing (add-label silently failed,
    # eventual consistency, concurrent cleanup) we treat it as a loss, not
    # a win.
    local after
    if ! after="$(_ccgl_read_labels "$issue")"; then
        printf '{"acquired": false, "lease_id": "%s", "reason": "backend_reverify_error"}\n' "$lease_id"
        return 1
    fi
    local all_claims
    all_claims="$(echo "$after" | grep "^claimed:" || true)"
    local claim_count
    claim_count="$(echo "$all_claims" | grep -c "^claimed:" || true)"

    if ! grep -Fxq "$our_label" <<< "$all_claims"; then
        printf '{"acquired": false, "lease_id": "%s", "reason": "our_label_missing_after_add"}\n' "$lease_id"
        return 0
    fi

    if [[ "$claim_count" -gt 1 ]]; then
        # Concurrent claim detected — drop ours and yield.
        _ccgl_remove_label "$issue" "$our_label" || true
        printf '{"acquired": false, "lease_id": "%s", "reason": "race_lost"}\n' "$lease_id"
        return 0
    fi

    printf '{"acquired": true, "lease_id": "%s"}\n' "$lease_id"
    return 0
}

# ─── Hook: release <issue_id> [lease_id] ──────────────────────────────────────
claim_coordinator_release() {
    local issue="$1"
    [[ -z "$issue" ]] && { error "claim_coordinator_release: missing issue id" >&2 || true; return 2; }
    local machine; machine="$(_ccgl_machine_id)"
    _ccgl_remove_label "$issue" "claimed:${machine}"
    return 0
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
            # `gh issue list --label` does NOT support wildcards or prefix
            # matches — `--label "claimed:"` looks for a label literally named
            # "claimed:". List labels first and filter for prefix `claimed:`.
            local labels_json
            if ! labels_json="$(gh label list --json name 2>/dev/null)"; then
                error "list_claims: 'gh label list' failed" >&2 || true
                return 1
            fi
            local claim_labels
            claim_labels="$(echo "$labels_json" \
                | jq -r '.[] | select(.name | startswith("claimed:")) | .name' 2>/dev/null \
                || true)"
            local results='[]'
            local label
            while IFS= read -r label; do
                [[ -z "$label" ]] && continue
                local issues_json
                if ! issues_json="$(gh issue list --label "$label" --json number 2>/dev/null)"; then
                    error "list_claims: 'gh issue list --label $label' failed" >&2 || true
                    return 1
                fi
                local holder="${label#claimed:}"
                results="$(echo "$results" | jq --arg h "$holder" --argjson issues "$issues_json" \
                    '. + ($issues | map({issue: .number, holder: $h, acquired_at: null}))')" \
                    || { error "list_claims: jq merge failed" >&2 || true; return 1; }
            done <<< "$claim_labels"
            echo "$results"
            ;;
        local-fs)
            local store="${ZBUILD_CLAIM_STORE:?}"
            local results='[]'
            local issue_dir issue holder
            for issue_dir in "$store"/*/; do
                [[ -d "$issue_dir" ]] || continue
                issue="$(basename "$issue_dir")"
                [[ -f "$issue_dir/labels.txt" ]] || continue
                holder="$(grep -m1 "^claimed:" "$issue_dir/labels.txt" | sed 's/^claimed://')"
                [[ -z "$holder" ]] && continue
                results="$(echo "$results" | jq --arg i "$issue" --arg h "$holder" \
                    '. + [{issue: ($i|tonumber), holder: $h, acquired_at: null}]')"
            done
            echo "$results"
            ;;
        *) echo '[]' ;;
    esac
    return 0
}
