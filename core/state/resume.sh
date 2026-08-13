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
#   "engine_sha": "51f11cd...",              // #1791: which engine graded this run
#   "engine_branch": "main",                 //        (ADR-023 freezes it per run)
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
    # #1791: which engine graded this run. ADR-023 freezes the engine per run, so
    # this is NOT recoverable after the fact from `git log` — record it or lose it.
    local engine_sha="${4:-unknown}"
    local engine_branch="${5:-unknown}"

    if [[ -f "$state_file" ]]; then
        warn "init_state: $state_file already exists; refusing to overwrite (use resume_state instead)"
        return 1
    fi

    local dir; dir="$(dirname "$state_file")"
    [[ -d "$dir" ]] || mkdir -p "$dir"

    jq -n \
        --arg run_id "$run_id" \
        --argjson issue "$issue" \
        --arg engine_sha "$engine_sha" \
        --arg engine_branch "$engine_branch" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            schema_version: 1,
            run_id: $run_id,
            issue: $issue,
            engine_sha: $engine_sha,
            engine_branch: $engine_branch,
            stage_statuses: {},
            current_iteration: 0,
            self_heal_count: {},
            scope_manifest_hash: "",
            cost_ledger_pointer: 0,
            claim_lease_id: "",
            plugin_state: {},
            updated_at: $now
        }' | atomic_write "$state_file"
    # ADR-006's resume contract starts here: an unchecked write leaves the run
    # with no persisted state and nothing to resume from, and `emit_event`
    # always returns 0 — so without this the caller sees success either way
    # (#1773). Read both stages: the producer's rc AND the writer's.
    #
    # Caller contract: invoke this as `if ! init_state ...` (or `|| ...`). A
    # bare call under `set -e` dies at the pipeline above, before these lines —
    # so the diagnostic and the partial-file cleanup below never run. Both
    # expansions must sit in ONE `local` so the first does not reset PIPESTATUS
    # before the second reads it.
    local _jq_rc="${PIPESTATUS[0]}" _write_rc="${PIPESTATUS[1]}"
    if (( _jq_rc != 0 )) || (( _write_rc != 0 )); then
        error "init_state: failed to write $state_file (jq rc=$_jq_rc, atomic_write rc=$_write_rc) — the run would proceed with no persisted state and nothing to resume from"
        rm -f "$state_file"
        return 1
    fi
    if [[ ! -s "$state_file" ]]; then
        error "init_state: $state_file is missing or empty after a reportedly successful write — refusing to proceed stateless"
        rm -f "$state_file"
        return 1
    fi

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

# ─── _zbuild_iso8601_to_epoch <ts> ──────────────────────────────────────────
# Both branches must interpret the string as UTC — otherwise every age boundary
# computed from it drifts by the local timezone offset (#299). Unparseable input
# prints 0, which makes the caller's age look enormous (i.e. stale, not fresh).
_zbuild_iso8601_to_epoch() {
    local ts="${1:-}"
    [[ -n "$ts" ]] || { printf '0\n'; return 0; }
    if date -u -d "$ts" +%s >/dev/null 2>&1; then
        date -u -d "$ts" +%s 2>/dev/null || printf '0\n'   # GNU date
    else
        TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || printf '0\n'   # BSD date
    fi
}

# ─── zbuild_run_is_live <state_file> ────────────────────────────────────────
# rc=0 when <state_file> describes a PROVABLY-live run: status=in_progress AND a
# fresh (<24h) updated_at. rc=1 otherwise — including every case where liveness
# cannot be established (missing file, no status, absent/unparseable timestamp).
#
# "Provably" is the whole contract, and the asymmetry is deliberate: liveness is
# what lets one run refuse to disturb another, so it must rest on positive
# evidence rather than on the absence of evidence. Same rule the SPEC-G
# collision guard applies to state writes (core/state/atomic.sh, #1215) and the
# same 24h gate get_resume_recommendation applies below — named once here so a
# caller that needs the question answered no longer has to re-derive it.
#
# Callers act on rc=1 in ways that are hard to reverse (reclaiming a dead run's
# worktree), so each is responsible for its OWN safety guard on the artifact it
# touches. This predicate answers "is a process still working here?", never
# "is destroying this safe?".
zbuild_run_is_live() {
    local state_file="${1:-}"
    [[ -n "$state_file" && -f "$state_file" ]] || return 1

    local status updated_at
    status="$(get_state_field "$state_file" '.status' '')"
    [[ "$status" == "in_progress" ]] || return 1

    updated_at="$(get_state_field "$state_file" '.updated_at' '')"
    [[ -n "$updated_at" ]] || return 1

    local updated_epoch now_epoch age_seconds
    updated_epoch="$(_zbuild_iso8601_to_epoch "$updated_at")"
    now_epoch="$(date -u +%s)"
    age_seconds=$(( now_epoch - updated_epoch ))
    [[ $age_seconds -lt 86400 ]]
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
            updated_epoch="$(_zbuild_iso8601_to_epoch "$updated_at")"
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
