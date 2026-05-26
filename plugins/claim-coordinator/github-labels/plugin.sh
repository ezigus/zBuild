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

# Local-fs helpers (test backend) ─────────────────────────────────────────────
_ccgl_lf_labels_file() {
    local issue="$1"
    local store="${ZBUILD_CLAIM_STORE:?ZBUILD_CLAIM_STORE must be set for local-fs backend}"
    mkdir -p "$store/$issue"
    echo "$store/$issue/labels.txt"
}

# Read labels for an issue (one per line); empty when file absent.
_ccgl_read_labels() {
    local issue="$1"
    case "$(_ccgl_backend)" in
        gh)
            gh issue view "$issue" --json labels --jq '.labels[].name' 2>/dev/null || true
            ;;
        local-fs)
            local f; f="$(_ccgl_lf_labels_file "$issue")"
            [[ -f "$f" ]] && cat "$f" || true
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
            (
                exec 9>"${f}.lock"
                flock 9
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
            (
                exec 9>"${f}.lock"
                flock 9
                grep -Fxv "$label" "$f" > "${f}.new" || true
                mv "${f}.new" "$f"
            )
            ;;
        *) return 1 ;;
    esac
}

# ─── Hook: init ───────────────────────────────────────────────────────────────
claim_coordinator_init() {
    local backend; backend="$(_ccgl_backend)"
    case "$backend" in
        gh)
            if ! command -v gh >/dev/null 2>&1; then
                error "claim-coordinator-github-labels: backend=gh but 'gh' CLI not in PATH" >&2 || true
                return 1
            fi
            ;;
        local-fs)
            if [[ -z "${ZBUILD_CLAIM_STORE:-}" ]]; then
                error "claim-coordinator-github-labels: backend=local-fs requires ZBUILD_CLAIM_STORE" >&2 || true
                return 1
            fi
            mkdir -p "$ZBUILD_CLAIM_STORE"
            ;;
        *)
            error "claim-coordinator-github-labels: unknown backend: $backend" >&2 || true
            return 1
            ;;
    esac
    return 0
}

# ─── Hook: claim <issue_id> ───────────────────────────────────────────────────
# stdout: {"acquired": bool, "lease_id": "<machine>:<issue>"}
# exit 0 on either acquired=true or acquired=false (claim is observable);
# non-zero only on backend errors.
claim_coordinator_claim() {
    local issue="$1"
    [[ -z "$issue" ]] && { error "claim_coordinator_claim: missing issue id" >&2 || true; return 2; }

    local machine; machine="$(_ccgl_machine_id)"
    local our_label="claimed:${machine}"
    local lease_id="${machine}:${issue}"

    # Phase 1: read current labels. If anyone else already holds it, refuse.
    local existing
    existing="$(_ccgl_read_labels "$issue")"
    if echo "$existing" | grep -q "^claimed:" && ! echo "$existing" | grep -Fxq "$our_label"; then
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

    # Phase 4: re-read. If anyone else also added a claimed: label, we lost the race.
    local after
    after="$(_ccgl_read_labels "$issue")"
    local other_claims
    other_claims="$(echo "$after" | grep "^claimed:" | grep -Fxv "$our_label" || true)"
    if [[ -n "$other_claims" ]]; then
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
claim_coordinator_list_claims() {
    case "$(_ccgl_backend)" in
        gh)
            # Pull issues with a claimed:* label.
            gh issue list --label "claimed:" --json number,labels 2>/dev/null \
                | jq -c '[ .[] | {issue: .number,
                                  holder: (.labels[] | select(.name | startswith("claimed:")) | .name | sub("^claimed:"; "")),
                                  acquired_at: null} ]' 2>/dev/null \
                || echo '[]'
            ;;
        local-fs)
            local store="${ZBUILD_CLAIM_STORE:?}"
            local results="[]"
            local issue_dir issue labels holder
            for issue_dir in "$store"/*/; do
                [[ -d "$issue_dir" ]] || continue
                issue="$(basename "$issue_dir")"
                [[ -f "$issue_dir/labels.txt" ]] || continue
                holder="$(grep "^claimed:" "$issue_dir/labels.txt" | head -1 | sed 's/^claimed://')"
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
