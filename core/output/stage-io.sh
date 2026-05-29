#!/usr/bin/env bash
# core/output/stage-io.sh — ADR-015 v1 stage-io capture chokepoint (issue #438)
# All stage I/O artifacts (LLM prompt/response, computed outputs) flow through
# capture_stage_io and are persisted under
# ${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}/artifacts/stage-io/<stage>-<seq>.json
# when the template's stage declares io.destinations. When no destinations
# are configured, this is a hot-path no-op (zero I/O, zero events).
#
# v1 scope: --kind=llm only (router call-site). command/computed deferred to
# downstream issues. Recognized destinations: file (functional), stdout and
# gh_comment (stubs — log "deferred to #440", return 0).
#
# Sourced library: inherits caller's pipefail settings; do not add
# set -euo pipefail at file scope (would mutate caller options).

[[ -n "${_ZBUILD_STAGE_IO_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_IO_LOADED=1

_STAGE_IO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT_FOR_STAGE_IO="$(cd "$_STAGE_IO_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/scripts/lib/helpers.sh"
# shellcheck source=../event-bus/event-bus.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/core/event-bus/event-bus.sh"
# shellcheck source=../pipeline/template.sh
source "$_ZBUILD_ROOT_FOR_STAGE_IO/core/pipeline/template.sh"

# ─── capture_stage_io — chokepoint ────────────────────────────────────────────
# Usage:
#   capture_stage_io --stage <id> --kind llm|command|computed \
#                    --input <str> --output <str> \
#                    [--exit-code N] [--duration-ms N] \
#                    [--metadata k=v]...
#
# Returns:
#   0 — success (capture written, or no destinations configured: no-op)
#   2 — usage error (missing required flag, unknown --kind, bad --metadata,
#                    schema-invalid built record)
capture_stage_io() {
    if [[ $# -eq 0 ]]; then
        error "capture_stage_io: usage: --stage <id> --kind llm|command|computed --input <s> --output <s> [--exit-code N] [--duration-ms N] [--metadata k=v]..."
        return 2
    fi

    local stage="" kind=""
    # Sentinels distinguish "flag never provided" from "flag provided with empty value".
    # Empty --input/--output is legitimate (e.g. LLM timeout/refusal producing empty output);
    # we only reject when the flag itself was omitted.
    local input="__ZBUILD_STAGE_IO_UNSET__"
    local output="__ZBUILD_STAGE_IO_UNSET__"
    local exit_code="" duration_ms=""
    # Bash 3.2: no associative arrays — use parallel arrays for metadata
    local -a meta_keys=() meta_vals=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage)        stage="${2:-}"; shift 2 ;;
            --kind)         kind="${2:-}"; shift 2 ;;
            --input)        input="${2:-}"; shift 2 ;;
            --output)       output="${2:-}"; shift 2 ;;
            --exit-code)    exit_code="${2:-}"; shift 2 ;;
            --duration-ms)  duration_ms="${2:-}"; shift 2 ;;
            --metadata)
                local kv="${2:-}"
                if [[ "$kv" != *"="* ]]; then
                    error "capture_stage_io: malformed --metadata '$kv' (expected key=value)"
                    return 2
                fi
                meta_keys+=("${kv%%=*}")
                meta_vals+=("${kv#*=}")
                shift 2
                ;;
            *)
                error "capture_stage_io: unknown flag '$1'"
                return 2
                ;;
        esac
    done

    # Required-flag validation
    if [[ -z "$stage" ]]; then
        error "capture_stage_io: --stage is required"
        return 2
    fi
    if [[ -z "$kind" ]]; then
        error "capture_stage_io: --kind is required"
        return 2
    fi
    case "$kind" in
        llm|command|computed) : ;;
        *) error "capture_stage_io: unknown --kind '$kind' (valid: llm, command, computed)"; return 2 ;;
    esac
    # --input / --output: empty string is legitimate (e.g. LLM timeout/refusal).
    # Sentinel tracking distinguishes "flag never provided" from "flag with empty value".
    if [[ "$input" == "__ZBUILD_STAGE_IO_UNSET__" ]]; then
        error "capture_stage_io: --input is required"
        return 2
    fi
    if [[ "$output" == "__ZBUILD_STAGE_IO_UNSET__" ]]; then
        error "capture_stage_io: --output is required"
        return 2
    fi
    # Strip sentinel before JSON build (defensive — both should be non-sentinel here).
    [[ "$input" == "__ZBUILD_STAGE_IO_UNSET__" ]] && input=""
    [[ "$output" == "__ZBUILD_STAGE_IO_UNSET__" ]] && output=""

    # ── Destination lookup — no destinations means no-op (hot path) ──────────
    local dests_nl
    dests_nl="$(template_stage_io_dests "$stage" 2>/dev/null || true)"
    if [[ -z "$dests_nl" ]]; then
        return 0
    fi

    # Build comma-delimited dest_list for event payload + iteration list
    local dests_comma
    dests_comma="$(printf '%s' "$dests_nl" | tr '\n' ',' | sed 's/,$//')"

    # ── seq: count existing <stage>-*.json under artifacts/stage-io ──────────
    # TODO: wrap with flock(1) once fanout strategy concurrently captures
    #       (out-of-scope for v1 single-writer LLM path).
    local state_dir="${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}"
    local io_dir="$state_dir/artifacts/stage-io"
    local existing_count=0
    if [[ -d "$io_dir" ]]; then
        # shellcheck disable=SC2012
        existing_count=$(ls -1 "$io_dir"/"${stage}"-*.json 2>/dev/null | wc -l | tr -d ' ')
    fi
    local seq=$((existing_count + 1))

    # ── Build JSON via jq --arg (NEVER string interp) ─────────────────────────
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local run_id="${ZBUILD_RUN_ID:-}"

    # Build metadata object
    local metadata_json='{}'
    local mi
    for (( mi=0; mi<${#meta_keys[@]}; mi++ )); do
        metadata_json="$(printf '%s' "$metadata_json" | \
            jq -c --arg k "${meta_keys[$mi]}" --arg v "${meta_vals[$mi]}" '. + {($k): $v}')" || {
            error "capture_stage_io: failed to assemble metadata"
            return 2
        }
    done

    # Numeric fields: default exit_code/duration_ms to null when unset.
    local record
    record="$(jq -n \
        --arg schema_version "1" \
        --arg run_id "$run_id" \
        --arg stage "$stage" \
        --arg kind "$kind" \
        --arg seq "$seq" \
        --arg input "$input" \
        --arg output "$output" \
        --arg exit_code "$exit_code" \
        --arg duration_ms "$duration_ms" \
        --argjson metadata "$metadata_json" \
        --arg ts "$ts" \
        '{
            schema_version: ($schema_version|tonumber),
            run_id: $run_id,
            stage: $stage,
            kind: $kind,
            seq: ($seq|tonumber),
            input: $input,
            output: $output,
            exit_code: (if $exit_code == "" then null else ($exit_code|tonumber) end),
            duration_ms: (if $duration_ms == "" then null else ($duration_ms|tonumber) end),
            metadata: $metadata,
            ts: $ts
        }')" || {
        error "capture_stage_io: jq assembly failed"
        eb_emit_event "stage.io.error" "stage=$stage" "reason=jq_assembly_failed" 2>/dev/null || true
        return 2
    }

    # Validate against locked schema
    if ! printf '%s' "$record" | jq -e \
        'has("schema_version") and .schema_version==1 and has("stage") and has("kind") and (.kind|IN("llm","command","computed")) and has("input") and has("output") and has("ts")' \
        >/dev/null 2>&1; then
        eb_emit_event "stage.io.error" "stage=$stage" "reason=schema_invalid" 2>/dev/null || true
        return 2
    fi

    # ── Dispatch to each destination ─────────────────────────────────────────
    local dest artifact_path=""
    local IFS_save="$IFS"; IFS=$'\n'
    local -a dests_arr=()
    # shellcheck disable=SC2206
    dests_arr=( $dests_nl )
    IFS="$IFS_save"

    for dest in "${dests_arr[@]}"; do
        [[ -z "$dest" ]] && continue
        case "$dest" in
            file)
                local _p
                _p="$(_stage_io_to_file "$stage" "$seq" "$record")" || return 2
                [[ -z "$artifact_path" ]] && artifact_path="$_p"
                ;;
            stdout)
                _stage_io_to_stdout "$record" || true
                ;;
            gh_comment)
                _stage_io_to_gh_comment "$record" || true
                ;;
            *)
                # Should be impossible — template loader rejects unknown tokens.
                error "capture_stage_io: unknown destination '$dest' (should have failed at template load)"
                return 2
                ;;
        esac
    done

    # ── Emit stage.io.captured AFTER successful write, BEFORE return ─────────
    eb_emit_event "stage.io.captured" \
        "stage=$stage" \
        "kind=$kind" \
        "seq=$seq" \
        "dest_list=$dests_comma" \
        "artifact_path=${artifact_path:-}" 2>/dev/null || true

    return 0
}

# ─── _stage_io_to_file <stage> <seq> <record_json> ───────────────────────────
# Writes the record to ${ZBUILD_STATE_DIR}/artifacts/stage-io/<stage>-<seq>.json
# atomically. Prints the resulting path on stdout so the caller can include it
# in the stage.io.captured event payload.
_stage_io_to_file() {
    local stage="$1" seq="$2" record="$3"
    local state_dir="${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}"
    local io_dir="$state_dir/artifacts/stage-io"
    mkdir -p "$io_dir" || { error "_stage_io_to_file: cannot create $io_dir"; return 1; }
    local path="$io_dir/${stage}-${seq}.json"
    if ! printf '%s\n' "$record" | atomic_write "$path"; then
        error "_stage_io_to_file: atomic_write failed for $path"
        return 1
    fi
    printf '%s' "$path"
    return 0
}

# ─── _stage_io_to_stdout — v1 stub, full impl deferred to #440 ───────────────
_stage_io_to_stdout() {
    info "stage-io stdout renderer deferred to #440" >&2
    return 0
}

# ─── _stage_io_to_gh_comment — v1 stub, full impl deferred to #440 ───────────
_stage_io_to_gh_comment() {
    info "stage-io gh_comment renderer deferred to #440" >&2
    return 0
}
