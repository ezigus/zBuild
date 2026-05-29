#!/usr/bin/env bash
# core/router/route.sh — ADR-003 model router stub (issue #84)
# Maps tier ordinals (T0-T4) to concrete models via config/models.json.
# Phase 0.5: picks candidates[0]; UCB1 bandit deferred to #29.
# Sourced by callers — no set -euo pipefail at file scope (would mutate caller options).

[[ -n "${_ZBUILD_ROUTER_LOADED:-}" ]] && return 0
_ZBUILD_ROUTER_LOADED=1

_ROUTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_ROUTER_DIR/../.." && pwd)"

source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
source "$_ZBUILD_ROOT/core/event-bus/event-bus.sh"
# ADR-015 v1 (#438): stage-io chokepoint — capture LLM prompt/response when
# the current stage declares io.destinations. Sourced library is idempotent.
source "$_ZBUILD_ROOT/core/output/stage-io.sh"

# route_to_model <tier> <prompt> [--skip-precondition] [--model <id>]
# Exit codes: 0=success, 1=recoverable, 2=fatal
#
# C6 precondition: most-recent event for the current run_id must be
# `redaction.applied`. See ARCHITECTURE.md §3 / ADR-004. `--skip-precondition`
# requires operator override (ZBUILD_SCOPE_OVERRIDE=1 + token file). ADR-001.
route_to_model() {
    if [[ $# -lt 2 ]]; then
        error "route_to_model requires <tier> <prompt>"
        return 2
    fi
    local tier="$1" prompt="$2"
    local skip_precondition=false model_override="" _prev_arg=""
    for arg in "${@:3}"; do
        [[ "$arg" == "--skip-precondition" ]] && skip_precondition=true
        [[ "${_prev_arg}" == "--model" ]] && model_override="$arg"
        _prev_arg="$arg"
    done

    if [[ ! "$tier" =~ ^T[0-4]$ ]]; then
        error "invalid tier '$tier' — must be T0-T4"; return 2
    fi
    if [[ "$tier" == "T0" ]]; then
        error "T0 (WASM) not implemented in Phase 0.5"; return 2
    fi

    _route_check_precondition "$tier" "$skip_precondition" || return $?
    _route_lookup_model "$tier" "$model_override"          || return $?

    # ADR-017 (#455): precedence-aware timeout resolution.
    # per-stage template router.timeout_s > ZBUILD_ROUTER_TIMEOUT env > 300s default.
    local secs; secs="$(_route_resolve_timeout)"
    if [[ ! "$secs" =~ ^[0-9]+$ ]] || [[ "$secs" -eq 0 ]]; then
        error "ZBUILD_ROUTER_TIMEOUT must be a positive integer (>=1), got: $secs"; return 2
    fi

    _route_emit_model_route "$tier" "$secs"
    _route_check_budget "$tier" || return $?

    _ROUTE_RESPONSE=""
    _route_call_claude "$tier" "$prompt" "$secs" || return $?

    _route_emit_outcome "$tier" "$secs"
    _route_update_ledger

    # ADR-015 v1 (#438): LLM-kind stage I/O capture.
    # No-op when the current stage has no io.destinations configured (or when
    # ZBUILD_CURRENT_STAGE is unset — e.g. ad-hoc CLI invocations).
    # Capture failure must not fail the router (hot path) — best-effort.
    if [[ -n "${ZBUILD_CURRENT_STAGE:-}" ]]; then
        capture_stage_io \
            --stage "$ZBUILD_CURRENT_STAGE" \
            --kind llm \
            --input "$prompt" \
            --output "$_ROUTE_RESPONSE" \
            --metadata "tier=$tier" \
            --metadata "model_id=$_ROUTE_MODEL_ID" \
            --metadata "input_tokens=${_ROUTE_INPUT_TOKENS:-0}" \
            --metadata "output_tokens=${_ROUTE_OUTPUT_TOKENS:-0}" \
            --metadata "cache_read=${_ROUTE_CACHE_READ:-0}" \
            --metadata "cache_creation=${_ROUTE_CACHE_CREATION:-0}" \
            >/dev/null || true
    fi

    printf '%s\n' "$_ROUTE_RESPONSE"
    return 0
}

# ── Shared state set by helpers ──────────────────────────────────────────────
_ROUTE_MODEL_ID="" _ROUTE_PROVIDER="" _ROUTE_COST_IN="" _ROUTE_COST_OUT=""
_ROUTE_CACHE_ELIGIBLE="false" _ROUTE_OVERRIDE_SOURCE="" _ROUTE_RESPONSE=""
_ROUTE_INPUT_TOKENS=0 _ROUTE_OUTPUT_TOKENS=0
_ROUTE_CACHE_READ=0 _ROUTE_CACHE_CREATION=0

# ─── _route_check_precondition <tier> <skip:bool> ────────────────────────────
# Validates C6: most-recent event for current run_id must be redaction.applied.
# `--skip-precondition` requires the operator override (ZBUILD_SCOPE_OVERRIDE=1
# + ~/.zbuild/scope-override-token matching run_id or 'bootstrap').
_route_check_precondition() {
    local tier="$1" skip_precondition="$2"

    if $skip_precondition; then
        local override_token="${HOME}/.zbuild/scope-override-token"
        local override_ok=false
        if [[ "${ZBUILD_SCOPE_OVERRIDE:-0}" == "1" && -f "$override_token" ]]; then
            local token_run_id; token_run_id="$(cat "$override_token" 2>/dev/null || echo "")"
            local rid="${ZBUILD_RUN_ID:-bootstrap}"
            [[ "$token_run_id" == "$rid" ]] && override_ok=true
        fi
        if ! $override_ok; then
            error "router C6 precondition refused: --skip-precondition requires ZBUILD_SCOPE_OVERRIDE=1 + ~/.zbuild/scope-override-token containing run_id (or 'bootstrap' if RUN_ID unset)"
            eb_emit_event "router.precondition.refused" \
                "tier=$tier" "reason=skip_without_override" \
                "run_id_state=${ZBUILD_RUN_ID:+set}${ZBUILD_RUN_ID:-unset}" 2>/dev/null || true
            return 2
        fi
        eb_emit_event "router.precondition.skipped" \
            "tier=$tier" "reason=skip_precondition_flag" \
            "run_id_state=${ZBUILD_RUN_ID:+set}${ZBUILD_RUN_ID:-unset}" 2>/dev/null || true
        return 0
    fi

    local run_id="${ZBUILD_RUN_ID:-}" events_log="${ZBUILD_EVENTS_JSONL:-}"

    if [[ -z "$run_id" ]]; then
        error "router C6 precondition refused: ZBUILD_RUN_ID is unset; cannot verify redaction.applied"
        eb_emit_event "router.precondition.refused" "tier=$tier" "reason=no_run_id" 2>/dev/null || true
        return 2
    fi
    if [[ -z "$events_log" || ! -f "$events_log" ]]; then
        error "router C6 precondition refused: ZBUILD_EVENTS_JSONL='${events_log}' missing; cannot verify redaction.applied for run_id=$run_id"
        eb_emit_event "router.precondition.refused" "tier=$tier" "reason=no_events_log" 2>/dev/null || true
        return 2
    fi

    local last_event_type
    last_event_type="$(jq -r --arg rid "$run_id" \
        'select(.run_id == $rid) | .type' "$events_log" 2>/dev/null | tail -1 || true)"

    if [[ -z "$last_event_type" ]]; then
        error "router C6 precondition refused: no events for run_id=$run_id"
        eb_emit_event "router.precondition.refused" "tier=$tier" "reason=no_events_for_run" 2>/dev/null || true
        return 2
    fi
    if [[ "$last_event_type" != "redaction.applied" ]]; then
        error "router C6 precondition violated: last event for run_id=$run_id was '$last_event_type', expected 'redaction.applied'"
        eb_emit_event "router.precondition.violated" "tier=$tier" \
            "last_event=$last_event_type" "required=redaction.applied"
        return 2
    fi
    return 0
}

# ─── _route_lookup_model <tier> <model_override> ─────────────────────────────
# Resolves model_id and cost metadata from models.json.
# Sets _ROUTE_MODEL_ID, _ROUTE_PROVIDER, _ROUTE_COST_IN, _ROUTE_COST_OUT,
# _ROUTE_CACHE_ELIGIBLE, _ROUTE_OVERRIDE_SOURCE.
_route_lookup_model() {
    local tier="$1" model_override="$2"

    local models_file="${ZBUILD_MODELS_FILE:-$_ZBUILD_ROOT/config/models.json}"
    if [[ ! -f "$models_file" ]]; then
        error "models.json not found: $models_file"; return 2
    fi

    local class
    class="$(jq -r ".tiers.${tier}.class // empty" "$models_file" 2>/dev/null)" \
        || { error "failed to parse models.json for tier $tier"; return 2; }
    if [[ -z "$class" ]]; then
        error "tier $tier not found in models.json"; return 2
    fi

    if [[ -n "$model_override" ]]; then
        _ROUTE_MODEL_ID="$model_override"
        _ROUTE_OVERRIDE_SOURCE="flag"
        _ROUTE_PROVIDER="" _ROUTE_COST_IN="" _ROUTE_COST_OUT="" _ROUTE_CACHE_ELIGIBLE="false"
    elif [[ -n "${ZBUILD_PLUGIN_MODEL:-}" ]]; then
        _ROUTE_MODEL_ID="$ZBUILD_PLUGIN_MODEL"
        _ROUTE_OVERRIDE_SOURCE="env"
        _ROUTE_PROVIDER="" _ROUTE_COST_IN="" _ROUTE_COST_OUT="" _ROUTE_CACHE_ELIGIBLE="false"
    else
        _ROUTE_MODEL_ID="$(jq -r ".tiers.${tier}.candidates[0].id // empty" "$models_file" 2>/dev/null)" \
            || { error "failed to read candidates for tier $tier"; return 2; }
        if [[ -z "$_ROUTE_MODEL_ID" ]]; then
            error "no candidates for tier $tier"; return 1
        fi
        _ROUTE_OVERRIDE_SOURCE="candidates[0]"
        _ROUTE_PROVIDER="$(jq -r ".tiers.${tier}.candidates[0].provider // empty" "$models_file" 2>/dev/null)" || _ROUTE_PROVIDER=""
        _ROUTE_COST_IN="$(jq -r ".tiers.${tier}.candidates[0].cost_per_input_mtok // empty" "$models_file" 2>/dev/null)" || _ROUTE_COST_IN=""
        _ROUTE_COST_OUT="$(jq -r ".tiers.${tier}.candidates[0].cost_per_output_mtok // empty" "$models_file" 2>/dev/null)" || _ROUTE_COST_OUT=""
        _ROUTE_CACHE_ELIGIBLE="$(jq -r ".tiers.${tier}.candidates[0].cache_eligible // false" "$models_file" 2>/dev/null)" || _ROUTE_CACHE_ELIGIBLE="false"
    fi
    return 0
}

# ─── _route_resolve_knob — ADR-017 (#455) precedence chokepoint ──────────────
# Generic helper: future knobs (tier_default, budget_usd, model_override) reuse
# this. Accessor returns per-stage value or empty; env_var supplies session-wide
# fallback; default is the compile-time floor.
_route_resolve_knob() {
    local accessor_fn="$1" env_var="$2" default_val="$3"
    local v=""
    if [[ -n "${ZBUILD_CURRENT_STAGE:-}" ]] && declare -F "$accessor_fn" >/dev/null 2>&1; then
        v="$($accessor_fn "$ZBUILD_CURRENT_STAGE" 2>/dev/null || true)"
    fi
    if [[ -n "$v" ]]; then
        # If env var ALSO set and differs, emit override-ignored event for audit.
        local env_val="${!env_var:-}"
        if [[ -n "$env_val" && "$env_val" != "$v" ]]; then
            eb_emit_event "router.timeout.override_ignored" \
                "stage=${ZBUILD_CURRENT_STAGE:-}" \
                "env_var=$env_var" \
                "env_value=$env_val" \
                "applied=$v" 2>/dev/null || true
        fi
        printf '%s\n' "$v"; return 0
    fi
    printf '%s\n' "${!env_var:-$default_val}"
}

# Concrete: per-stage router.timeout_s > $ZBUILD_ROUTER_TIMEOUT > 300s default.
_route_resolve_timeout() {
    _route_resolve_knob template_stage_router_timeout ZBUILD_ROUTER_TIMEOUT 300
}

# ─── _route_emit_model_route <tier> <timeout_s> ──────────────────────────────
_route_emit_model_route() {
    local tier="$1" secs="${2:-}"
    eb_emit_event "model.route" \
        "tier=$tier" \
        "model_id=$_ROUTE_MODEL_ID" \
        "provider=${_ROUTE_PROVIDER:-}" \
        "recommended=$_ROUTE_MODEL_ID" \
        "applied=$_ROUTE_MODEL_ID" \
        "selector=${_ROUTE_OVERRIDE_SOURCE}" \
        "override_source=${_ROUTE_OVERRIDE_SOURCE}" \
        "cost_per_input_mtok=${_ROUTE_COST_IN:-}" \
        "cost_per_output_mtok=${_ROUTE_COST_OUT:-}" \
        "cache_eligible=${_ROUTE_CACHE_ELIGIBLE}" \
        "timeout_s=${secs}"
}

# ─── _route_check_budget <tier> ──────────────────────────────────────────────
# Returns 1 (recoverable) if ZBUILD_BUDGET_USD is set and exceeded.
_route_check_budget() {
    local tier="$1"
    local _budget_usd="${ZBUILD_BUDGET_USD:-}"
    [[ -z "$_budget_usd" ]] && return 0

    local _ledger_file="${HOME}/.zbuild/cost-ledger.jsonl"
    local _total_cost=0
    [[ -f "$_ledger_file" ]] && \
        _total_cost="$(awk '{s+=$1} END{printf "%.6f", s+0}' "$_ledger_file" 2>/dev/null || echo 0)"

    local _over_budget
    _over_budget="$(awk -v tot="$_total_cost" -v bud="$_budget_usd" \
        'BEGIN{print (tot+0 >= bud+0) ? "1" : "0"}')"
    if [[ "$_over_budget" == "1" ]]; then
        error "router: token budget exceeded (spent=${_total_cost} budget=${_budget_usd}) — refusing model call for tier=$tier"
        eb_emit_event "cost.budget_exceeded" "tier=$tier" \
            "model_id=$_ROUTE_MODEL_ID" "spent=${_total_cost}" "budget=${_budget_usd}" 2>/dev/null || true
        return 1
    fi
    return 0
}

# ─── _route_call_claude <tier> <prompt> <timeout_secs> ───────────────────────
# Executes the claude CLI. Sets _ROUTE_RESPONSE (avoids subshell variable leak).
# Returns 1 on recoverable error, 2 on fatal error.
_route_call_claude() {
    local tier="$1" prompt="$2" secs="$3"

    if ! command -v claude >/dev/null 2>&1; then
        error "claude binary not found in PATH — cannot route tier=$tier"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "reason=claude_binary_missing"
        return 1
    fi

    local -a _tout_cmd=()
    if   command -v gtimeout >/dev/null 2>&1; then _tout_cmd=("gtimeout" "$secs")
    elif command -v timeout  >/dev/null 2>&1; then _tout_cmd=("timeout"  "$secs")
    fi

    local -a _claude_args=(-p "$prompt" --print --model "$_ROUTE_MODEL_ID")
    [[ "${ZBUILD_ROUTER_JSON_OUTPUT:-0}" == "1" ]] && _claude_args+=(--output-format json)

    local stderr_file rc=0
    if ! stderr_file="$(mktemp "${TMPDIR:-/tmp}/zb-router-stderr.XXXXXX" 2>/dev/null)"; then
        error "router: mktemp failed"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "reason=mktemp_failed"
        return 2
    fi

    local response
    if [[ ${#_tout_cmd[@]} -gt 0 ]]; then
        response="$("${_tout_cmd[@]}" claude "${_claude_args[@]}" 2>"$stderr_file")" || rc=$?
    else
        response="$(claude "${_claude_args[@]}" 2>"$stderr_file")" || rc=$?
    fi

    if [[ $rc -ne 0 ]]; then
        local snip; snip="$(head -c 200 "$stderr_file" 2>/dev/null || true)"
        rm -f "$stderr_file"
        error "claude CLI failed (rc=$rc) model=$_ROUTE_MODEL_ID tier=$tier${snip:+: $snip}"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "rc=$rc" "reason=claude_cli_failed"
        return 1
    fi
    rm -f "$stderr_file"

    if [[ -z "$response" ]]; then
        error "claude CLI returned empty response model=$_ROUTE_MODEL_ID tier=$tier"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "reason=empty_response"
        return 1
    fi

    # JSON output mode: extract .result and token counts
    _ROUTE_INPUT_TOKENS=0 _ROUTE_OUTPUT_TOKENS=0
    _ROUTE_CACHE_READ=0 _ROUTE_CACHE_CREATION=0
    if [[ "${ZBUILD_ROUTER_JSON_OUTPUT:-0}" == "1" ]]; then
        local text_response
        text_response="$(printf '%s' "$response" | jq -r '.result // empty' 2>/dev/null || true)"
        if [[ -z "$text_response" ]]; then
            error "router: JSON output mode active but .result missing — response: ${response:0:120}"
            eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" "reason=json_result_missing"
            return 1
        fi
        _ROUTE_INPUT_TOKENS="$(printf '%s' "$response" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo 0)"
        _ROUTE_OUTPUT_TOKENS="$(printf '%s' "$response" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo 0)"
        _ROUTE_CACHE_READ="$(printf '%s' "$response" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null || echo 0)"
        _ROUTE_CACHE_CREATION="$(printf '%s' "$response" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || echo 0)"
        response="$text_response"
    fi

    _ROUTE_RESPONSE="$response"
    return 0
}

# ─── _route_emit_outcome <tier> <timeout_s> ──────────────────────────────────
_route_emit_outcome() {
    local tier="$1" secs="${2:-}"
    eb_emit_event "model.outcome" \
        "tier=$tier" \
        "model_id=$_ROUTE_MODEL_ID" \
        "cache_eligible=${_ROUTE_CACHE_ELIGIBLE}" \
        "input_tokens=$_ROUTE_INPUT_TOKENS" \
        "output_tokens=$_ROUTE_OUTPUT_TOKENS" \
        "cache_read_input_tokens=$_ROUTE_CACHE_READ" \
        "cache_creation_input_tokens=$_ROUTE_CACHE_CREATION" \
        "timeout_s=${secs}"
}

# ─── _route_update_ledger ─────────────────────────────────────────────────────
# Appends call cost to ~/.zbuild/cost-ledger.jsonl. Non-fatal on failure.
_route_update_ledger() {
    [[ -z "${_ROUTE_COST_IN:-}" || -z "${_ROUTE_COST_OUT:-}" ]] && return 0

    local _call_cost_usd
    _call_cost_usd="$(awk \
        -v i="$_ROUTE_INPUT_TOKENS" -v o="$_ROUTE_OUTPUT_TOKENS" \
        -v ri="$_ROUTE_COST_IN" -v ro="$_ROUTE_COST_OUT" \
        'BEGIN{printf "%.6f", (i*ri + o*ro)/1000000}' 2>/dev/null || echo 0)"

    [[ "$_call_cost_usd" == "0" || "$_call_cost_usd" == "0.000000" ]] && return 0

    local _ledger_dir="${HOME}/.zbuild" _ledger_file="${HOME}/.zbuild/cost-ledger.jsonl"
    mkdir -p "$_ledger_dir" 2>/dev/null || true
    if zbuild_has_flock; then
        (
            flock -w 5 9 || exit 1
            printf '%s\n' "$_call_cost_usd" >> "$_ledger_file"
        ) 9>"${_ledger_file}.lock" 2>/dev/null || true
    else
        printf '%s\n' "$_call_cost_usd" >> "$_ledger_file" 2>/dev/null || true
    fi
}
