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

# route_to_model <tier> <prompt> [--skip-precondition]
# Exit codes:
#   0 — success
#   1 — recoverable (no candidates, claude CLI / API error)
#   2 — fatal (invariant violation: invalid args, misconfiguration, OR a C6
#       precondition refusal — see below)
#
# C6 precondition (ARCHITECTURE.md §3 / ADR-004): before emitting model.route,
# verify that the most-recent event for the current run_id is `redaction.applied`.
# If not, emits `router.precondition.violated` and returns rc=2.
#
# Issue #289 (rescoped 2026-05-26): the precondition is fail-closed in three
# ways, each emitting a single `router.precondition.refused` event with a
# stable `reason=...` field (grep target). All refusals return rc=2 — the
# safety violation is fatal, not recoverable, so callers don't silently
# degrade by treating it as a transient failure.
#   1. `--skip-precondition` not passed AND last event != redaction.applied
#      → emits `router.precondition.violated`, rc=2.
#   2. `--skip-precondition` not passed AND `ZBUILD_RUN_ID` unset
#      → emits `router.precondition.refused` with reason=no_run_id, rc=2.
#      Previously the inner `[[ -n "$run_id" && -f ... ]]` silently no-op'd
#      this case and let the router proceed unverified.
#   3. `--skip-precondition` not passed AND events log missing/empty
#      → emits `router.precondition.refused` with reason=no_events_log, rc=2.
#   4. `--skip-precondition` not passed AND no events for this run_id
#      → emits `router.precondition.refused` with reason=no_events_for_run, rc=2.
#
# `--skip-precondition` is intended for bootstrapping (router self-test, early
# pipeline init before the redaction chokepoint runs) and unit tests that
# don't model the event bus. It is gated behind the SAME operator-override
# pair that `apply_scope_redaction` uses (ADR-004 §Operator override):
#   - ZBUILD_SCOPE_OVERRIDE=1
#   - ~/.zbuild/scope-override-token contains the current ZBUILD_RUN_ID
# Both conditions must hold OR the bypass is refused (rc=2). The token file
# must be created by the operator each run (one-shot). Every accepted bypass
# emits an audited `router.precondition.skipped` event.
route_to_model() {
    if [[ $# -lt 2 ]]; then
        error "route_to_model requires <tier> <prompt>"
        return 2
    fi
    local tier="$1" prompt="$2"
    local skip_precondition=false
    # Check for optional --skip-precondition flag (must come after tier and prompt)
    local arg
    for arg in "${@:3}"; do
        [[ "$arg" == "--skip-precondition" ]] && skip_precondition=true
    done

    if [[ ! "$tier" =~ ^T[0-4]$ ]]; then
        error "invalid tier '$tier' — must be T0-T4"
        return 2
    fi

    if [[ "$tier" == "T0" ]]; then
        error "T0 (WASM) not implemented in Phase 0.5"
        return 2
    fi

    # ── C6 precondition: most-recent event for run_id must be redaction.applied ──
    # This enforces ARCHITECTURE.md §3: "Every box that emits LLM-bound text passes
    # through redaction.apply(). There is no other path."
    if $skip_precondition; then
        # Operator override gate (parallel to apply_scope_redaction):
        # require ZBUILD_SCOPE_OVERRIDE=1 AND a token file matching the
        # current run_id. Either condition missing → refuse the bypass.
        local override_token="${HOME}/.zbuild/scope-override-token"
        local override_ok=false
        if [[ "${ZBUILD_SCOPE_OVERRIDE:-0}" == "1" && -f "$override_token" ]]; then
            local token_run_id; token_run_id="$(cat "$override_token" 2>/dev/null || echo "")"
            # When ZBUILD_RUN_ID is unset (bootstrap path), accept a token of
            # the literal "bootstrap" so the gate is still operator-asserted.
            local rid="${ZBUILD_RUN_ID:-bootstrap}"
            [[ "$token_run_id" == "$rid" ]] && override_ok=true
        fi
        if ! $override_ok; then
            error "router C6 precondition refused: --skip-precondition requires ZBUILD_SCOPE_OVERRIDE=1 + ~/.zbuild/scope-override-token containing run_id (or 'bootstrap' if RUN_ID unset)"
            eb_emit_event "router.precondition.refused" \
                "tier=$tier" \
                "reason=skip_without_override" \
                "run_id_state=${ZBUILD_RUN_ID:+set}${ZBUILD_RUN_ID:-unset}" 2>/dev/null || true
            return 2
        fi
        # Audited bypass — emit an event so the override is observable in logs.
        # We rely on the envelope's run_id; payload only records that the
        # override was authorised + how the run_id was sourced.
        eb_emit_event "router.precondition.skipped" \
            "tier=$tier" \
            "reason=skip_precondition_flag" \
            "run_id_state=${ZBUILD_RUN_ID:+set}${ZBUILD_RUN_ID:-unset}" 2>/dev/null || true
    else
        local run_id="${ZBUILD_RUN_ID:-}"
        local events_log="${ZBUILD_EVENTS_JSONL:-}"

        # Fail-closed: ZBUILD_RUN_ID must be set (#289). rc=2 (fatal) so
        # callers don't silently degrade and route unverified prompts.
        if [[ -z "$run_id" ]]; then
            error "router C6 precondition refused: ZBUILD_RUN_ID is unset; cannot verify redaction.applied. Pass --skip-precondition only with operator override (ZBUILD_SCOPE_OVERRIDE + token)."
            eb_emit_event "router.precondition.refused" \
                "tier=$tier" \
                "reason=no_run_id" 2>/dev/null || true
            return 2
        fi

        # Fail-closed: events log must exist (#289).
        if [[ -z "$events_log" || ! -f "$events_log" ]]; then
            error "router C6 precondition refused: ZBUILD_EVENTS_JSONL='${events_log}' missing or empty; cannot verify redaction.applied for run_id=$run_id."
            eb_emit_event "router.precondition.refused" \
                "tier=$tier" \
                "reason=no_events_log" 2>/dev/null || true
            return 2
        fi

        local last_event_type
        last_event_type="$(jq -r --arg rid "$run_id" \
            'select(.run_id == $rid) | .type' \
            "$events_log" 2>/dev/null | tail -1 || true)"

        # Fail-closed: no events found for this run_id (#289).
        if [[ -z "$last_event_type" ]]; then
            error "router C6 precondition refused: no events found in $events_log for run_id=$run_id; cannot verify redaction.applied."
            eb_emit_event "router.precondition.refused" \
                "tier=$tier" \
                "reason=no_events_for_run" 2>/dev/null || true
            return 2
        fi

        if [[ "$last_event_type" != "redaction.applied" ]]; then
            error "router C6 precondition violated: last event for run_id=$run_id was '$last_event_type', expected 'redaction.applied'"
            eb_emit_event "router.precondition.violated" \
                "tier=$tier" \
                "last_event=$last_event_type" \
                "required=redaction.applied"
            return 2
        fi
    fi

    # Config cascade: env override → project default (optimization path wired in #29)
    local models_file="${ZBUILD_MODELS_FILE:-$_ZBUILD_ROOT/config/models.json}"
    if [[ ! -f "$models_file" ]]; then
        error "models.json not found: $models_file"
        return 2
    fi

    local class
    class="$(jq -r ".tiers.${tier}.class // empty" "$models_file" 2>/dev/null)" \
        || { error "failed to parse models.json for tier $tier"; return 2; }
    if [[ -z "$class" ]]; then
        error "tier $tier not found in models.json"
        return 2
    fi

    local model_id
    model_id="$(jq -r ".tiers.${tier}.candidates[0].id // empty" "$models_file" 2>/dev/null)" \
        || { error "failed to read candidates for tier $tier"; return 2; }
    if [[ -z "$model_id" ]]; then
        error "no candidates for tier $tier"
        return 1
    fi

    local provider cost_in cost_out
    provider="$(jq -r ".tiers.${tier}.candidates[0].provider // empty" "$models_file" 2>/dev/null)" || provider=""
    cost_in="$(jq -r ".tiers.${tier}.candidates[0].cost_per_input_mtok // empty" "$models_file" 2>/dev/null)" || cost_in=""
    cost_out="$(jq -r ".tiers.${tier}.candidates[0].cost_per_output_mtok // empty" "$models_file" 2>/dev/null)" || cost_out=""

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

    # Validate timeout is a positive integer before building the command.
    local secs="${ZBUILD_ROUTER_TIMEOUT:-120}"
    if [[ ! "$secs" =~ ^[0-9]+$ ]]; then
        error "ZBUILD_ROUTER_TIMEOUT must be a positive integer, got: $secs"
        return 2
    fi

    # Timeout cascade (ported from legacy/scripts/sw-intelligence.sh:374-387):
    # macOS ships gtimeout via coreutils; Linux has timeout; some envs have neither.
    # Build as an array to avoid word-splitting on $secs.
    local -a _tout_cmd=()
    if   command -v gtimeout >/dev/null 2>&1; then _tout_cmd=("gtimeout" "$secs")
    elif command -v timeout  >/dev/null 2>&1; then _tout_cmd=("timeout"  "$secs")
    fi

    # Check for claude binary before attempting call — emit deterministic error if missing.
    if ! command -v claude >/dev/null 2>&1; then
        error "claude binary not found in PATH — cannot route tier=$tier"
        eb_emit_event "router.error" \
            "tier=$tier" \
            "model_id=$model_id" \
            "reason=claude_binary_missing"
        return 1
    fi

    local response rc=0
    local stderr_file
    # Use an explicit template so mktemp behaves identically on GNU and BSD
    # (bare `mktemp` without args is not portable across all BSD variants;
    # Copilot caught this on #278).
    if ! stderr_file="$(mktemp "${TMPDIR:-/tmp}/zb-router-stderr.XXXXXX" 2>/dev/null)"; then
        error "router: mktemp failed; refusing to fall back to a predictable shared path"
        eb_emit_event "router.error" \
            "tier=$tier" \
            "model_id=$model_id" \
            "reason=mktemp_failed"
        return 2
    fi
    # Use -p to pass prompt as argument (matches established claude CLI usage pattern).
    if [[ ${#_tout_cmd[@]} -gt 0 ]]; then
        response="$("${_tout_cmd[@]}" claude -p "$prompt" --print --model "$model_id" 2>"$stderr_file")" || rc=$?
    else
        response="$(claude -p "$prompt" --print --model "$model_id" 2>"$stderr_file")" || rc=$?
    fi

    if [[ $rc -ne 0 ]]; then
        local stderr_snippet; stderr_snippet="$(head -c 200 "$stderr_file" 2>/dev/null || true)"
        rm -f "$stderr_file"
        error "claude CLI failed (rc=$rc) model=$model_id tier=$tier${stderr_snippet:+: $stderr_snippet}"
        eb_emit_event "router.error" \
            "tier=$tier" \
            "model_id=$model_id" \
            "rc=$rc" \
            "reason=claude_cli_failed"
        return 1
    fi
    rm -f "$stderr_file"

    # Validate response is non-empty (partial/empty response = recoverable error)
    if [[ -z "$response" ]]; then
        error "claude CLI returned empty response model=$model_id tier=$tier"
        eb_emit_event "router.error" \
            "tier=$tier" \
            "model_id=$model_id" \
            "reason=empty_response"
        return 1
    fi

    printf '%s\n' "$response"
    return 0
}
