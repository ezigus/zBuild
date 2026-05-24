#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild core/state/resume — persisted vs reconstructed state              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Implements the ADR-006 resume contract.
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
#   "current_iteration": 3,                  // <-- explicitly persisted (fixes shipwright gap)
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
