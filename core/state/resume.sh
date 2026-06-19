#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild core/state/resume — persisted vs reconstructed state              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Implements the ADR-006 resume contract.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.
#
# Persisted (survives kill -9, host restart):
#   - stage_statuses, current_iteration, self_heal_count, scope_manifest_hash,
#     cost_ledger_pointer, plugin_state[*], claim_lease_id
#
# Reconstructed on resume (computed by each plugin's init or core init):
#   - git_diff, repo_hash, env_snapshot, router_recommendations, etc.

[[ -n "${_ZBUILD_STATE_RESUME_LOADED:-}" ]] && return 0
_ZBUILD_STATE_RESUME_LOADED=1

_ZBUILD_RESUME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./atomic.sh
source "$_ZBUILD_RESUME_DIR/atomic.sh"

# ─── State file schema ──────────────────────────────────────────────────────
# {
#   "schema_version": 1,
#   "run_id": "uuid",
#   "issue": 42,
#   "stage_statuses": { "plan": "complete", "build": "in_progress", ... },
#   "current_iteration": 3,                  // <-- explicitly persisted (fixes legacy resume gap)
#   "self_heal_count": { "build": 1 },
#   "scope_manifest_hash": "sha256...",
#   "cost_ledger_pointer": 1248,
#   "claim_lease_id": "machine-x:run-uuid",
#   "plugin_state": {
#     "security-lens": { "last_cycle_score": 95, ... }
#   },
#   "updated_at": "2026-05-24T12:34:56.789Z"
# }

# ─── init_state ─────────────────────────────────────────────────────────────
init_state() {
    local state_file="$1"
    local run_id="${2:-$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "run-$$-$(date +%s)")}"
    local issue="${3:-0}"

    if [[ -f "$state_file" ]]; then
        warn "init_state: $state_file already exists; refusing to overwrite (use resume_state instead)"
        return 1
    fi

    local dir; dir="$(dirname "$state_file")"
    [[ -d "$dir" ]] || mkdir -p "$dir"

    jq -n \
        --arg run_id "$run_id" \
        --argjson issue "$issue" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            schema_version: 1,
            run_id: $run_id,
            issue: $issue,
            stage_statuses: {},
            current_iteration: 0,
            self_heal_count: {},
            scope_manifest_hash: "",
            cost_ledger_pointer: 0,
            claim_lease_id: "",
            plugin_state: {},
            updated_at: $now
        }' | atomic_write "$state_file"

    emit_event "pipeline.init" "run_id=$run_id" "issue=$issue" "state_file=$state_file"
}

# ─── resume_state ───────────────────────────────────────────────────────────
# Loads persisted state. Reconstructs derived values (caller responsibility).
# Returns 0 on success (state usable); non-zero if state unreadable / wrong schema.
resume_state() {
    local state_file="$1"
    local state_json
    if ! state_json="$(read_state "$state_file")"; then
        error "resume_state: cannot read $state_file"
        return 1
    fi
    local schema_version
    schema_version="$(echo "$state_json" | jq -r '.schema_version // 0')"
    if [[ "$schema_version" != "1" ]]; then
        error "resume_state: unsupported schema_version: $schema_version (expected 1)"
        return 2
    fi

    # Restore the canonical fields. Callers read via get_state_field.
    emit_event "pipeline.resume" \
        "run_id=$(echo "$state_json" | jq -r .run_id)" \
        "issue=$(echo "$state_json" | jq -r .issue)" \
        "current_iteration=$(echo "$state_json" | jq -r .current_iteration)" \
        "state_file=$state_file"

    return 0
}

# ─── get_state_field / set_state_field ──────────────────────────────────────
get_state_field() {
    local state_file="$1"
    local jq_path="$2"
    local default="${3:-}"
    if [[ ! -f "$state_file" ]]; then
        echo "$default"
        return 0
    fi
    # Validate and attempt .bak recovery before reading. rc=2 is unrecoverable
    # (main and .bak both corrupt, or the .bak restore itself failed) → default.
    # Suppress stderr — callers are read-only and must not be flooded by warnings.
    local _gsf_rc=0
    validate_json "$state_file" >/dev/null 2>&1 || _gsf_rc=$?
    if (( _gsf_rc == 2 )); then
        echo "$default"
        return 0
    fi
    local val
    val="$(jq -r "$jq_path // \"$default\"" "$state_file" 2>/dev/null || echo "$default")"
    echo "$val"
}

# Internal update function used with locked_state_update
_zbuild_state_set_field() {
    # Reads current state from stdin, writes updated state to stdout
    # Inputs: _ZB_FIELD_PATH (jq path), _ZB_FIELD_VALUE (string)
    jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --argjson value "$_ZB_FIELD_VALUE_JSON" \
       "$_ZB_FIELD_PATH = \$value | .updated_at = \$now"
}

set_state_field() {
    local state_file="$1"
    local jq_path="$2"      # e.g., '.current_iteration'
    local value_json="$3"   # JSON-encoded value, e.g., '3' or '"complete"'

    export _ZB_FIELD_PATH="$jq_path"
    export _ZB_FIELD_VALUE_JSON="$value_json"
    locked_state_update "$state_file" "_zbuild_state_set_field"
    unset _ZB_FIELD_PATH _ZB_FIELD_VALUE_JSON
}

# ─── increment_iteration ────────────────────────────────────────────────────
# Convenience: bump current_iteration atomically.
increment_iteration() {
    local state_file="$1"
    local current
    current="$(get_state_field "$state_file" '.current_iteration' '0')"
    local next=$((current + 1))
    set_state_field "$state_file" '.current_iteration' "$next"
    echo "$next"
}

# ─── get_resume_recommendation ──────────────────────────────────────────────
# Returns one of: auto_resume, manual_resume_only, fresh_start
#
# Decision table (ADR-006):
#   status=in_progress  AND last event < 24h → auto_resume
#   status=in_progress  AND last event ≥ 24h → manual_resume_only
#   status=interrupted                        → auto_resume
#   status=aborted                            → manual_resume_only
#   status=complete  (or missing)             → fresh_start
get_resume_recommendation() {
    local state_file="$1"

    if [[ ! -f "$state_file" ]]; then
        echo "fresh_start"
        return 0
    fi

    local status updated_at
    status="$(get_state_field "$state_file" '.status' '')"
    updated_at="$(get_state_field "$state_file" '.updated_at' '')"

    case "$status" in
        complete|"")
            echo "fresh_start"
            ;;
        aborted)
            echo "manual_resume_only"
            ;;
        interrupted)
            echo "auto_resume"
            ;;
        in_progress)
            # Check if last update was within 24 hours
            if [[ -z "$updated_at" ]]; then
                echo "manual_resume_only"
                return 0
            fi
            local updated_epoch now_epoch age_seconds
            # Parse ISO-8601 'Z' timestamp to epoch seconds.
            # Both branches must interpret the string as UTC — otherwise the
            # 24h boundary drifts by the local timezone offset (#299 surfaced).
            if date -u -d "$updated_at" +%s >/dev/null 2>&1; then
                # GNU date
                updated_epoch="$(date -u -d "$updated_at" +%s 2>/dev/null || echo 0)"
            else
                # BSD date (macOS) — force UTC interpretation with TZ=UTC so
                # 'Z'-suffixed ISO strings parse to the right epoch.
                updated_epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$updated_at" +%s 2>/dev/null || echo 0)"
            fi
            now_epoch="$(date -u +%s)"
            age_seconds=$(( now_epoch - updated_epoch ))
            if [[ $age_seconds -lt 86400 ]]; then
                echo "auto_resume"
            else
                echo "manual_resume_only"
            fi
            ;;
        *)
            echo "fresh_start"
            ;;
    esac
    return 0
}
