#!/usr/bin/env bash
# core/router/route.sh — ADR-003 model router stub (issue #84)
# Maps tier ordinals (T0-T4) to concrete models via config/models.json.
# Phase 0.5: picks candidates[0]; UCB1 bandit deferred to #29.
set -euo pipefail

[[ -n "${_ZBUILD_ROUTER_LOADED:-}" ]] && return 0
_ZBUILD_ROUTER_LOADED=1

_ROUTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_ROUTER_DIR/../.." && pwd)"

source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
source "$_ZBUILD_ROOT/core/event-bus/event-bus.sh"

# route_to_model <tier> <prompt>
# Exit codes: 0=success, 1=recoverable (no candidates / claude API error), 2=fatal
route_to_model() {
    local tier="$1" prompt="$2"

    # Validate tier format
    if [[ ! "$tier" =~ ^T[0-4]$ ]]; then
        error "invalid tier '$tier' — must be T0-T4"
        return 2
    fi

    # T0 WASM not implemented in Phase 0.5
    if [[ "$tier" == "T0" ]]; then
        error "T0 (WASM) not implemented in Phase 0.5"
        return 2
    fi

    # Config cascade: env override → project default (optimization path wired in #29)
    local models_file="${ZBUILD_MODELS_FILE:-$_ZBUILD_ROOT/config/models.json}"
    if [[ ! -f "$models_file" ]]; then
        error "models.json not found: $models_file"
        return 2
    fi

    local class
    class="$(jq -r ".tiers.${tier}.class // empty" "$models_file")"
    if [[ -z "$class" ]]; then
        error "tier $tier not found in models.json"
        return 2
    fi

    local model_id
    model_id="$(jq -r ".tiers.${tier}.candidates[0].id // empty" "$models_file")"
    if [[ -z "$model_id" ]]; then
        error "no candidates for tier $tier"
        return 1
    fi

    local provider cost_in cost_out
    provider="$(jq -r ".tiers.${tier}.candidates[0].provider // empty" "$models_file")"
    cost_in="$(jq -r ".tiers.${tier}.candidates[0].cost_per_input_mtok // empty" "$models_file")"
    cost_out="$(jq -r ".tiers.${tier}.candidates[0].cost_per_output_mtok // empty" "$models_file")"

    # Event duality: recommended + applied both = candidates[0] in Phase 0.5 (UCB1 → #29)
    # Cost fields logged here for offline computation in #28
    eb_emit_event "model.route" \
        "tier=$tier" \
        "model_id=$model_id" \
        "provider=${provider:-}" \
        "recommended=$model_id" \
        "applied=$model_id" \
        "selector=candidates[0]" \
        "cost_per_input_mtok=${cost_in:-}" \
        "cost_per_output_mtok=${cost_out:-}"

    # Timeout cascade (ported from legacy/scripts/sw-intelligence.sh:374-387):
    # macOS ships gtimeout via coreutils; Linux has timeout; some envs have neither.
    local secs="${ZBUILD_ROUTER_TIMEOUT:-120}" _tout=""
    if   command -v gtimeout >/dev/null 2>&1; then _tout="gtimeout $secs"
    elif command -v timeout  >/dev/null 2>&1; then _tout="timeout $secs"
    fi

    local response rc=0
    # printf over echo: avoids -n/-e flag interpretation (legacy/scripts/lib/pipeline-stages-build.sh:67)
    response="$(printf '%s\n' "$prompt" | ${_tout} claude --print --model "$model_id" 2>/dev/null)" || rc=$?

    if [[ $rc -ne 0 ]]; then
        error "claude CLI failed (rc=$rc) model=$model_id tier=$tier"
        return 1
    fi

    printf '%s\n' "$response"
    return 0
}
