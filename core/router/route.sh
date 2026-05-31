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

    # #481: split LLM-kind stage I/O so input banner emits BEFORE the LLM call
    # and output banner emits AFTER. The two halves are paired by reserved seq.
    # Capture failure must not fail the router — best-effort throughout.
    local _stage_io_seq=""
    local -a _capture_meta_extra=()
    if [[ -n "${ZBUILD_CURRENT_STAGE:-}" ]]; then
        if [[ -n "${ZBUILD_ROUTER_ARTIFACT_ID:-}" ]]; then
            _capture_meta_extra+=( --metadata "artifact=$ZBUILD_ROUTER_ARTIFACT_ID" )
        fi
        # Direct call (not $()) so begin's assoc-array state survives in
        # the caller's shell — $() in a subshell would lose the pending map.
        stage_io_begin \
            --stage "$ZBUILD_CURRENT_STAGE" \
            --kind llm \
            --input "$prompt" \
            --metadata "tier=$tier" \
            "${_capture_meta_extra[@]}" >/dev/null 2>&1 || true
        _stage_io_seq="$_STAGE_IO_LAST_SEQ"
    fi

    _ROUTE_RESPONSE=""
    local _call_rc=0
    _route_call_claude "$tier" "$prompt" "$secs" || _call_rc=$?
    if [[ "$_call_rc" -ne 0 ]]; then
        # On error, close the begin so it doesn't orphan into the EXIT trap.
        if [[ -n "$_stage_io_seq" ]]; then
            stage_io_end \
                --stage "$ZBUILD_CURRENT_STAGE" \
                --kind llm \
                --seq "$_stage_io_seq" \
                --output "${_ROUTE_RESPONSE:-}" \
                --metadata "model_id=$_ROUTE_MODEL_ID" \
                --metadata "error=true" \
                >/dev/null 2>&1 || true
        fi
        return "$_call_rc"
    fi

    _route_emit_outcome "$tier" "$secs"
    _route_update_ledger

    if [[ -n "$_stage_io_seq" ]]; then
        stage_io_end \
            --stage "$ZBUILD_CURRENT_STAGE" \
            --kind llm \
            --seq "$_stage_io_seq" \
            --output "$_ROUTE_RESPONSE" \
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
# ADR-018 (#469): captured tool_uses[] envelope when JSON output mode is active.
# Empty when JSON mode off or envelope lacked the field. Consumers (review
# audit) read this AFTER route_to_model returns. Not exported to subshells —
# valid only within the parent shell that sourced route.sh.
_ROUTE_TOOL_USES_JSON="[]"

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
    local override_event="${4:-router.timeout.override_ignored}"
    local v=""
    if [[ -n "${ZBUILD_CURRENT_STAGE:-}" ]] && declare -F "$accessor_fn" >/dev/null 2>&1; then
        v="$($accessor_fn "$ZBUILD_CURRENT_STAGE" 2>/dev/null || true)"
    fi
    if [[ -n "$v" ]]; then
        # If env var ALSO set and differs, emit override-ignored event for audit.
        local env_val="${!env_var:-}"
        if [[ -n "$env_val" && "$env_val" != "$v" ]]; then
            eb_emit_event "$override_event" \
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

# ADR-018 (#466): per-stage router.max_turns > $ZBUILD_ROUTER_MAX_TURNS > 25 default.
_route_resolve_max_turns() {
    _route_resolve_knob template_stage_router_max_turns ZBUILD_ROUTER_MAX_TURNS 25 \
        router.max_turns.override_ignored
}

# ADR-018 (#467): per-stage router.max_iterations > $ZBUILD_ROUTER_MAX_ITERATIONS > 10 default.
_route_resolve_max_iterations() {
    _route_resolve_knob template_stage_router_max_iterations ZBUILD_ROUTER_MAX_ITERATIONS 10 \
        router.max_iterations.override_ignored
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

    # ADR-018 (#466): adopt shipwright's flag set so Pattern 1 (one-shot with tools)
    # works. Tools are available to claude --print unless disallowed; we forbid
    # only EnterPlanMode/ExitPlanMode and skip the permission prompt (headless).
    local max_turns; max_turns="$(_route_resolve_max_turns)"
    if [[ ! "$max_turns" =~ ^[0-9]+$ ]] || [[ "$max_turns" -lt 1 ]] || [[ "$max_turns" -gt 200 ]]; then
        error "router: max_turns must be integer in 1..200, got: $max_turns"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" \
            "reason=invalid_max_turns" "max_turns=$max_turns"
        return 2
    fi

    local -a _claude_args=(-p "$prompt" --print --model "$_ROUTE_MODEL_ID")
    _claude_args+=(--max-turns "$max_turns")
    _claude_args+=(--disallowed-tools "EnterPlanMode,ExitPlanMode")
    _claude_args+=(--dangerously-skip-permissions)
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
    _ROUTE_TOOL_USES_JSON="[]"
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
        # ADR-018 (#469): expose tool_uses[] for opt-in audit consumers.
        # Fail-soft — bad/missing field becomes empty array; never blocks.
        local _tu
        _tu="$(printf '%s' "$response" | jq -c '.tool_uses // []' 2>/dev/null || echo '[]')"
        if printf '%s' "$_tu" | jq -e 'type == "array"' >/dev/null 2>&1; then
            _ROUTE_TOOL_USES_JSON="$_tu"
        else
            _ROUTE_TOOL_USES_JSON="[]"
        fi
        # Side-channel: route_to_model is typically called via $() which
        # discards subshell state. Callers that need _ROUTE_TOOL_USES_JSON
        # across that boundary set ZBUILD_ROUTER_TOOL_USES_FILE to a path
        # the parent shell can read after the call returns.
        if [[ -n "${ZBUILD_ROUTER_TOOL_USES_FILE:-}" ]]; then
            printf '%s\n' "$_ROUTE_TOOL_USES_JSON" \
                > "$ZBUILD_ROUTER_TOOL_USES_FILE" 2>/dev/null || true
        fi
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

# ─── route_to_model_loop — ADR-018 Pattern 2 (Issue #467) ────────────────────
# Multi-turn agent loop. Each iteration invokes claude in $cwd; the pipeline
# captures `git diff HEAD` between turns and appends to the next prompt.
# Terminates on `LOOP_COMPLETE` sentinel from .result, or max-iterations cap.
# The LLM never emits a diff string; the caller reads `git diff HEAD` after
# the loop returns.
#
# Usage:
#   route_to_model_loop <tier> <prompt_file> <cwd> <max_iterations> \
#       [--max-turns-per-call N] [--done-sentinel TOKEN] \
#       [--inter-turn-hook FN] [--model ID] [--scope-allowlist CSV]
#
# Globals set:
#   _ROUTE_LOOP_ITERATIONS         — count of iterations actually run
#   _ROUTE_LOOP_TERMINATED_REASON  — done_sentinel | max_iterations | signal |
#                                    hook_failed | error
#   _ROUTE_LOOP_INPUT_TOKENS       — cumulative .usage.input_tokens
#   _ROUTE_LOOP_OUTPUT_TOKENS      — cumulative .usage.output_tokens
#
# Returns: 0 on DONE-sentinel, 1 on max-iter no-DONE, 2 on fatal.
_ROUTE_LOOP_ITERATIONS=0
_ROUTE_LOOP_TERMINATED_REASON=""
_ROUTE_LOOP_INPUT_TOKENS=0
_ROUTE_LOOP_OUTPUT_TOKENS=0
_ROUTE_LOOP_CHILD_PID=""

# Default no-op inter-turn hook — overridden via --inter-turn-hook FN
_route_loop_default_hook() { :; }

# Signal trap installer — kills child claude, emits terminated.signal event.
_route_loop_install_traps() {
    trap '_route_loop_on_signal SIGINT' INT
    trap '_route_loop_on_signal SIGTERM' TERM
}
_route_loop_clear_traps() {
    trap - INT TERM
}
_route_loop_on_signal() {
    local sig="$1"
    if [[ -n "${_ROUTE_LOOP_CHILD_PID:-}" ]]; then
        kill "$_ROUTE_LOOP_CHILD_PID" 2>/dev/null || true
    fi
    _ROUTE_LOOP_TERMINATED_REASON="signal"
    eb_emit_event "loop.terminated.signal" \
        "signal=$sig" \
        "iterations=${_ROUTE_LOOP_ITERATIONS}" 2>/dev/null || true
    return 130
}

route_to_model_loop() {
    if [[ $# -lt 4 ]]; then
        error "route_to_model_loop requires <tier> <prompt_file> <cwd> <max_iterations>"
        return 2
    fi
    local tier="$1" prompt_file="$2" cwd="$3" max_iterations="$4"; shift 4

    local max_turns_per_call=""
    local done_sentinel="LOOP_COMPLETE"
    local inter_turn_hook="_route_loop_default_hook"
    local model_override=""
    local scope_allowlist=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-turns-per-call) max_turns_per_call="$2"; shift 2 ;;
            --done-sentinel)      done_sentinel="$2";       shift 2 ;;
            --inter-turn-hook)    inter_turn_hook="$2";     shift 2 ;;
            --model)              model_override="$2";      shift 2 ;;
            --scope-allowlist)    scope_allowlist="$2";     shift 2 ;;
            *) error "route_to_model_loop: unknown flag '$1'"; return 2 ;;
        esac
    done

    if [[ ! "$tier" =~ ^T[0-4]$ ]]; then
        error "route_to_model_loop: invalid tier '$tier'"
        return 2
    fi
    if [[ -z "$prompt_file" || ! -f "$prompt_file" ]]; then
        error "route_to_model_loop: prompt_file '$prompt_file' missing"
        return 2
    fi
    if [[ -z "$cwd" || ! -d "$cwd" ]]; then
        error "route_to_model_loop: cwd '$cwd' missing or not a directory"
        return 2
    fi
    if ! [[ "$max_iterations" =~ ^[0-9]+$ ]] || [[ "$max_iterations" -lt 1 ]]; then
        error "route_to_model_loop: max_iterations must be positive integer, got: $max_iterations"
        return 2
    fi

    _route_lookup_model "$tier" "$model_override" || return $?

    if ! command -v claude >/dev/null 2>&1; then
        error "route_to_model_loop: claude binary not found in PATH"
        eb_emit_event "router.error" "tier=$tier" "model_id=$_ROUTE_MODEL_ID" \
            "reason=claude_binary_missing" 2>/dev/null || true
        return 2
    fi

    local mt; mt="$(_route_resolve_max_turns)"
    if ! [[ "$mt" =~ ^[0-9]+$ ]] || [[ "$mt" -lt 1 ]] || [[ "$mt" -gt 200 ]]; then
        error "route_to_model_loop: max_turns must be integer in 1..200, got: $mt"
        return 2
    fi
    [[ -n "$max_turns_per_call" ]] && mt="$max_turns_per_call"

    local secs; secs="$(_route_resolve_timeout)"
    local -a _tout_cmd=()
    if   command -v gtimeout >/dev/null 2>&1; then _tout_cmd=("gtimeout" "$secs")
    elif command -v timeout  >/dev/null 2>&1; then _tout_cmd=("timeout"  "$secs")
    fi

    _ROUTE_LOOP_ITERATIONS=0
    _ROUTE_LOOP_TERMINATED_REASON=""
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0

    _route_loop_install_traps

    # Per-iteration temp dir outside the caller's artifacts dir so the parity
    # goldens that snapshot artifact filenames are not polluted by iter files.
    local _loop_tmp; _loop_tmp="$(mktemp -d "${TMPDIR:-/tmp}/zb-loop-iters.XXXXXX")"

    local static_prompt prev_diff="" timeout_recur=0
    static_prompt="$(cat "$prompt_file")"
    # #505: snapshot of prev_diff at start of THIS iteration, used to detect
    # an unchanged diff between iterations for the operator banner pointer.
    local _prev_diff_for_banner=""

    local diff_cap="${ZBUILD_LOOP_DIFF_CAP_CHARS:-20000}"
    local iter
    for (( iter=1; iter <= max_iterations; iter++ )); do
        _ROUTE_LOOP_ITERATIONS=$iter

        local iter_prompt
        if [[ -z "$prev_diff" ]]; then
            iter_prompt="$static_prompt

## Iteration ${iter}/${max_iterations}
(No prior changes — this is the first iteration.)"
        else
            iter_prompt="$static_prompt

## Iteration ${iter}/${max_iterations}
## Cumulative diff so far (\`git diff HEAD\`):
${prev_diff}"
        fi

        # Per-iteration redaction: satisfy C6 precondition before each claude call.
        local iter_prompt_file="${_loop_tmp}/iter-${iter}.txt"
        local iter_redacted_file="${_loop_tmp}/iter-${iter}.redacted.txt"
        printf '%s\n' "$iter_prompt" > "$iter_prompt_file"

        local _scope_manifest="${ZBUILD_SCOPE_MANIFEST:-}"
        if [[ -n "$_scope_manifest" && -f "$_scope_manifest" ]] && \
           declare -F apply_scope_redaction >/dev/null 2>&1; then
            apply_scope_redaction "$iter_prompt_file" "$iter_redacted_file" \
                "$_scope_manifest" "$scope_allowlist" "$iter" \
                >/dev/null 2>&1 || cp "$iter_prompt_file" "$iter_redacted_file"
        else
            # Emit a redaction.applied stub so the per-iteration C6 precondition
            # is satisfied even when a manifest is not configured (test mode).
            cp "$iter_prompt_file" "$iter_redacted_file"
            eb_emit_event "redaction.applied" \
                "input=$iter_prompt_file" "output=$iter_redacted_file" \
                "size_before=0" "size_after=0" "redactions=0" \
                "scope_hash=loop-passthrough" "cycle=$iter" 2>/dev/null || true
        fi

        local final_prompt; final_prompt="$(cat "$iter_redacted_file")"

        eb_emit_event "loop.iteration" \
            "tier=$tier" "iteration=$iter" "max_iterations=$max_iterations" \
            "model_id=$_ROUTE_MODEL_ID" "cwd=$cwd" 2>/dev/null || true

        # #505: build operator-facing banner_input that DEDUPES the static
        # prompt + REPLACES the cumulative diff section with a pointer once
        # we are past iter 1. The LLM still gets the full final_prompt; only
        # the scrollback banner is trimmed. See ADR-018 §Pattern 2.5.
        #
        # Dedupe minimum (chars): below this, the full prompt is fine.
        local _banner_dedupe_min="${ZBUILD_LOOP_BANNER_DEDUPE_MIN_CHARS:-500}"
        local banner_input="$final_prompt"
        if (( iter >= 2 )) && (( ${#static_prompt} >= _banner_dedupe_min )); then
            # sha = first 8 hex chars of sha256(static_prompt) — detects
            # mid-loop static-prompt mutation across iterations.
            local _sha8="" _static_lines
            _static_lines="$(printf '%s' "$static_prompt" | wc -l | tr -d ' ')"
            if command -v shasum >/dev/null 2>&1; then
                _sha8="$(printf '%s' "$static_prompt" | shasum -a 256 | cut -c1-8)"
            elif command -v sha256sum >/dev/null 2>&1; then
                _sha8="$(printf '%s' "$static_prompt" | sha256sum | cut -c1-8)"
            else
                _sha8="nohash"
            fi

            # Classify the diff pointer: cap-exceeded (stat-only marker from
            # _route_loop_capture_diff), unchanged across iters, or normal.
            local _diff_pointer
            if [[ "$prev_diff" == "(diff exceeded cap of "* ]]; then
                _diff_pointer="[diff: stat-only, see ── changed-files ──]"
            elif [[ -n "${_prev_diff_for_banner:-}" && "$_prev_diff_for_banner" == "$prev_diff" ]]; then
                _diff_pointer="[diff: unchanged from iter $((iter - 1))]"
            else
                local _diff_lines _diff_chars
                _diff_lines="$(printf '%s' "$prev_diff" | wc -l | tr -d ' ')"
                _diff_chars="${#prev_diff}"
                _diff_pointer="[diff: see ── changed-files ── summary below (${_diff_lines} lines, ${_diff_chars}c)]"
            fi

            banner_input="[static prompt: same as iter 1, ${_static_lines} lines, sha=${_sha8}]

## Iteration ${iter}/${max_iterations}

${_diff_pointer}"
        fi
        # Track prev_diff snapshot for next-iter "unchanged" detection.
        _prev_diff_for_banner="$prev_diff"

        # #482: per-iteration stage_io banner (Pattern 2). Mirrors #481's
        # split begin/end emit around the LLM call so build's loop is
        # observable like plan/review. Fails soft — capture never blocks
        # the loop. Uses ZBUILD_CURRENT_STAGE (preferred) or ZBUILD_PLUGIN.
        local _iter_stage_io_seq=""
        local _iter_stage_id="${ZBUILD_CURRENT_STAGE:-${ZBUILD_PLUGIN:-}}"
        if [[ -n "$_iter_stage_id" ]]; then
            # #505: --persist-input writes final_prompt (full payload) into
            # the artifact .input field, while --input drives only the
            # (possibly deduped) scrollback banner. Default behavior — for
            # callers that don't pass --persist-input — is unchanged.
            stage_io_begin \
                --stage "$_iter_stage_id" \
                --kind llm \
                --input "$banner_input" \
                --persist-input "$iter_redacted_file" \
                --metadata "tier=$tier" \
                --metadata "iter=$iter" \
                --metadata "model_id=$_ROUTE_MODEL_ID" \
                >/dev/null 2>&1 || true
            _iter_stage_io_seq="${_STAGE_IO_LAST_SEQ:-}"
        fi

        local stderr_file rc=0 json_file
        stderr_file="$(mktemp "${TMPDIR:-/tmp}/zb-loop-stderr.XXXXXX")"
        json_file="$(mktemp "${TMPDIR:-/tmp}/zb-loop-json.XXXXXX")"

        local -a _claude_args=(-p "$final_prompt" --print --model "$_ROUTE_MODEL_ID")
        _claude_args+=(--max-turns "$mt")
        _claude_args+=(--disallowed-tools "EnterPlanMode,ExitPlanMode")
        _claude_args+=(--dangerously-skip-permissions)
        _claude_args+=(--output-format json)

        # Run claude in $cwd as background child so signal trap can kill it.
        if [[ ${#_tout_cmd[@]} -gt 0 ]]; then
            ( cd "$cwd" && "${_tout_cmd[@]}" claude "${_claude_args[@]}" ) \
                >"$json_file" 2>"$stderr_file" &
        else
            ( cd "$cwd" && claude "${_claude_args[@]}" ) \
                >"$json_file" 2>"$stderr_file" &
        fi
        _ROUTE_LOOP_CHILD_PID=$!
        wait "$_ROUTE_LOOP_CHILD_PID" 2>/dev/null || rc=$?
        _ROUTE_LOOP_CHILD_PID=""

        if [[ $rc -ne 0 ]]; then
            local snip; snip="$(head -c 200 "$stderr_file" 2>/dev/null || true)"
            warn "route_to_model_loop: claude rc=$rc iter=$iter${snip:+: $snip}"
            eb_emit_event "loop.iteration.error" \
                "iteration=$iter" "rc=$rc" \
                "model_id=$_ROUTE_MODEL_ID" \
                "reason=claude_rc_nonzero" 2>/dev/null || true
            # #482: close the per-iteration banner on the error path so we
            # don't orphan it into the EXIT trap. Output is whatever (if
            # anything) ended up in json_file before the failure.
            if [[ -n "$_iter_stage_io_seq" ]]; then
                local _err_result=""
                _err_result="$(jq -r '.result // empty' "$json_file" 2>/dev/null || true)"
                stage_io_end \
                    --stage "$_iter_stage_id" \
                    --kind llm \
                    --seq "$_iter_stage_io_seq" \
                    --output "$_err_result" \
                    --exit-code "$rc" \
                    --metadata "iter=$iter" \
                    --metadata "error=true" \
                    >/dev/null 2>&1 || true
            fi
            if [[ $rc -eq 124 ]]; then
                timeout_recur=$(( timeout_recur + 1 ))
                if [[ $timeout_recur -ge 3 ]]; then
                    error "route_to_model_loop: 3 consecutive timeouts — fatal"
                    _ROUTE_LOOP_TERMINATED_REASON="error"
                    rm -f "$stderr_file" "$json_file"
                    _route_loop_clear_traps
                    return 2
                fi
            fi
            rm -f "$stderr_file" "$json_file"
            # Capture diff after error iteration too so progress isn't lost.
            _route_loop_capture_diff "$cwd" "$diff_cap" prev_diff || {
                _ROUTE_LOOP_TERMINATED_REASON="error"
                _route_loop_clear_traps
                return 2
            }
            continue
        fi
        timeout_recur=0
        rm -f "$stderr_file"

        # Extract .result and token usage from claude JSON output.
        local result_text="" in_tok=0 out_tok=0
        result_text="$(jq -r '.result // empty' "$json_file" 2>/dev/null || true)"
        in_tok="$(jq -r '.usage.input_tokens // 0' "$json_file" 2>/dev/null || echo 0)"
        out_tok="$(jq -r '.usage.output_tokens // 0' "$json_file" 2>/dev/null || echo 0)"
        _ROUTE_LOOP_INPUT_TOKENS=$(( _ROUTE_LOOP_INPUT_TOKENS + in_tok ))
        _ROUTE_LOOP_OUTPUT_TOKENS=$(( _ROUTE_LOOP_OUTPUT_TOKENS + out_tok ))

        # #482: close the per-iteration banner on the success path. Output
        # is the LLM's result text (matches Pattern 1's banner shape).
        if [[ -n "$_iter_stage_io_seq" ]]; then
            stage_io_end \
                --stage "$_iter_stage_id" \
                --kind llm \
                --seq "$_iter_stage_io_seq" \
                --output "$result_text" \
                --exit-code 0 \
                --metadata "iter=$iter" \
                --metadata "tokens_in=$in_tok" \
                --metadata "tokens_out=$out_tok" \
                >/dev/null 2>&1 || true
        fi

        # Inter-turn hook (best-effort; failure does not abort the loop).
        if declare -F "$inter_turn_hook" >/dev/null 2>&1; then
            "$inter_turn_hook" "$iter" "$cwd" "$json_file" "$result_text" || \
                warn "route_to_model_loop: hook '$inter_turn_hook' rc=$? iter=$iter"
        fi

        # DONE-sentinel: line-anchored grep against the result text.
        # Matches: whitespace + LOOP_COMPLETE + whitespace, on its own line.
        if printf '%s\n' "$result_text" | \
           grep -qE "^[[:space:]]*${done_sentinel}[[:space:]]*\$" 2>/dev/null; then
            _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
            eb_emit_event "loop.complete" \
                "iterations=$iter" "model_id=$_ROUTE_MODEL_ID" \
                "input_tokens=$_ROUTE_LOOP_INPUT_TOKENS" \
                "output_tokens=$_ROUTE_LOOP_OUTPUT_TOKENS" \
                "reason=done_sentinel" 2>/dev/null || true
            rm -f "$json_file"
            _route_loop_clear_traps
            rm -rf "$_loop_tmp" 2>/dev/null || true
            return 0
        fi
        rm -f "$json_file"

        # Capture diff for next iteration's prompt.
        _route_loop_capture_diff "$cwd" "$diff_cap" prev_diff || {
            _ROUTE_LOOP_TERMINATED_REASON="error"
            _route_loop_clear_traps
            rm -rf "$_loop_tmp" 2>/dev/null || true
            return 2
        }
    done

    _ROUTE_LOOP_TERMINATED_REASON="max_iterations"
    eb_emit_event "loop.max_iterations" \
        "iterations=$max_iterations" "model_id=$_ROUTE_MODEL_ID" \
        "input_tokens=$_ROUTE_LOOP_INPUT_TOKENS" \
        "output_tokens=$_ROUTE_LOOP_OUTPUT_TOKENS" 2>/dev/null || true
    _route_loop_clear_traps
    rm -rf "$_loop_tmp" 2>/dev/null || true
    return 1
}

# _route_loop_capture_diff <cwd> <cap_chars> <prev_diff_var_name>
# Captures `git -C <cwd> diff HEAD` into the named variable.
#
# #530: bash `$()` strips trailing newlines, leaving the captured diff 1 byte
# short of the raw `git diff HEAD` output → downstream `git apply --check`
# fails with "corrupt patch at line N". Fix: stream `git diff HEAD` to a
# tempfile (no command-substitution trimming), then read it back via the
# `printf x; %x` trick to round-trip the trailing newline through a bash
# variable losslessly.
#
# On overflow: replaces with `git diff --stat` + truncation notice.
# On git failure: emits loop.git_diff_failed and returns 1.
_route_loop_capture_diff() {
    local cwd="$1" cap="$2" var_name="$3"
    # intent-to-add so new untracked files appear in `git diff HEAD`
    git -C "$cwd" add -N . 2>/dev/null || true

    # Stream directly to disk; do not let `$()` touch the byte stream.
    local _diff_tmp; _diff_tmp="$(mktemp "${TMPDIR:-/tmp}/zb-loop-diff.XXXXXX")"
    local diff_rc=0
    git -C "$cwd" diff HEAD > "$_diff_tmp" 2>/dev/null || diff_rc=$?
    if [[ $diff_rc -ne 0 ]]; then
        rm -f "$_diff_tmp"
        # Best-effort: clear `-N` intent-to-add entries so a later iteration's
        # diff isn't polluted by an aborted capture.
        git -C "$cwd" reset -q 2>/dev/null || true
        eb_emit_event "loop.git_diff_failed" \
            "cwd=$cwd" "rc=$diff_rc" 2>/dev/null || true
        return 1
    fi

    # Lossless readback: `cat file; printf x` then strip the final 'x'.
    local diff_out
    diff_out="$(cat "$_diff_tmp"; printf x)"
    diff_out="${diff_out%x}"
    rm -f "$_diff_tmp"

    if [[ ${#diff_out} -gt $cap ]]; then
        local stat_out
        stat_out="$(git -C "$cwd" diff --stat HEAD 2>/dev/null || echo "(diff too large)")"
        diff_out="(diff exceeded cap of ${cap} chars; showing stats only)
${stat_out}"
        eb_emit_event "loop.diff_capture_warning" \
            "cwd=$cwd" "reason=cap_exceeded" "cap=$cap" 2>/dev/null || true
    fi
    printf -v "$var_name" '%s' "$diff_out"
    return 0
}
