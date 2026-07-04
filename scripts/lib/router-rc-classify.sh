#!/usr/bin/env bash
# scripts/lib/router-rc-classify.sh — map router rc to verdict + reason (#782).
#
# Why this exists: route_to_model's underlying `claude` invocation goes
# through `gtimeout`. rc=124 specifically means TIMEOUT — an infra failure
# distinct from the model emitting an incorrect answer (rc=1 with payload)
# or claude itself erroring (rc != 0,124,137). ADR-021 v2 codifies a separate
# `error` verdict class for infra-origin failures so the cycle's blocked-
# predicate can distinguish them from recoverable `fail` verdicts.
#
# Public function:
#   _router_rc_classify <rc> <verdict_var> <reason_var> [rate_limited]
#     - On rc=0: verdict="" reason=""  (caller treats as success)
#     - On rc=124: verdict="error" reason="router_timeout"
#     - On rc=137: verdict="error" reason="router_oom_kill"  (SIGKILL by OOM)
#     - On other rc>0: verdict="fail" reason="router_rc_nonzero"
#     - When rate_limited=="1" (#1237): verdict="fail" reason="router_rate_limited"
#       regardless of rc. The claude CLI reports a rate/session limit as rc=1
#       with a MISLEADING subtype:"success" envelope carrying is_error:true +
#       api_error_status ∈ {429,529} (or limit/overloaded text). The router
#       detects it (_router_is_rate_limit) and passes the flag so the operator
#       gets an honest disposition instead of the opaque router_rc_nonzero.
#       verdict stays "fail" (recoverable), NOT the ADR-021 "error" class — a
#       rate-limit resets at a future time, so it must not halt a cycle as an
#       infra error nor be immediately auto-retried.

# Idempotent source guard.
if [[ "${_ZBUILD_ROUTER_RC_CLASSIFY_LOADED:-}" == "1" ]]; then
    return 0
fi
_ZBUILD_ROUTER_RC_CLASSIFY_LOADED=1

# _router_is_rate_limit <claude_output_json> — returns 0 when the envelope
# carries a rate/session/usage limit signal, 1 otherwise. Repo-agnostic: keys
# only on the claude CLI's own fields, never on prompt/response content.
_router_is_rate_limit() {
    local json="${1:-}"
    [[ -z "$json" ]] && return 1
    local status="" is_error="" result="" errtext=""
    if command -v jq >/dev/null 2>&1; then
        status="$(printf '%s' "$json"  | jq -r '.api_error_status // empty' 2>/dev/null || true)"
        is_error="$(printf '%s' "$json" | jq -r '.is_error // empty'        2>/dev/null || true)"
        result="$(printf '%s' "$json"   | jq -r '.result // empty'          2>/dev/null || true)"
        errtext="$(printf '%s' "$json"  | jq -r '.error // empty'           2>/dev/null || true)"
    fi
    # Primary signal: HTTP 429 (rate/session limit) or 529 (overloaded).
    case "$status" in 429|529) return 0 ;; esac
    # Secondary: an errored envelope whose message names a limit/overload.
    if [[ "$is_error" == "true" ]]; then
        local hay; hay="$(printf '%s\n%s' "$result" "$errtext" | tr '[:upper:]' '[:lower:]')"
        case "$hay" in
            *"session limit"*|*"rate limit"*|*"rate-limit"*|*"usage limit"*|\
            *quota*|*overloaded*|*"too many requests"*) return 0 ;;
        esac
    fi
    # Fallback for non-JSON / jq-absent output: conservative raw scan requiring
    # BOTH an error marker AND a limit keyword so ordinary content never trips.
    if [[ -z "$status$is_error$result$errtext" ]]; then
        local low; low="$(printf '%s' "$json" | tr '[:upper:]' '[:lower:]')"
        case "$low" in
            *'"api_error_status":429'*|*'"api_error_status":529'*|\
            *'"api_error_status": 429'*|*'"api_error_status": 529'*) return 0 ;;
        esac
        if [[ "$low" == *'"is_error":true'* || "$low" == *'"is_error": true'* ]]; then
            case "$low" in
                *"session limit"*|*"rate limit"*|*overloaded*|*quota*|\
                *"too many requests"*) return 0 ;;
            esac
        fi
    fi
    return 1
}

# _router_rate_limit_message <claude_output_json> — build the honest operator
# line, surfacing the reset time when the CLI provides one.
_router_rate_limit_message() {
    local json="${1:-}"
    local result="" status="" tail=""
    if command -v jq >/dev/null 2>&1; then
        result="$(printf '%s' "$json" | jq -r '.result // empty'          2>/dev/null || true)"
        status="$(printf '%s' "$json" | jq -r '.api_error_status // empty' 2>/dev/null || true)"
    fi
    if [[ "$result" =~ ([Rr]esets.*) ]]; then
        tail="${BASH_REMATCH[1]}"
    fi
    if [[ -n "$tail" ]]; then
        printf 'LLM rate-limited — %s' "$tail"
    elif [[ -n "$result" ]]; then
        printf 'LLM rate-limited — %s' "$result"
    elif [[ -n "$status" ]]; then
        printf 'LLM rate-limited (HTTP %s) — retry after the limit resets' "$status"
    else
        printf 'LLM rate-limited — retry after the limit resets'
    fi
}

_router_rc_classify() {
    local rc="$1" verdict_var="$2" reason_var="$3" rate_limited="${4:-0}"
    if [[ "$rate_limited" == "1" ]]; then
        printf -v "$verdict_var" '%s' "fail"
        printf -v "$reason_var"  '%s' "router_rate_limited"
        return 0
    fi
    case "$rc" in
        0)
            printf -v "$verdict_var" '%s' ""
            printf -v "$reason_var"  '%s' ""
            ;;
        124)
            printf -v "$verdict_var" '%s' "error"
            printf -v "$reason_var"  '%s' "router_timeout"
            ;;
        137)
            printf -v "$verdict_var" '%s' "error"
            printf -v "$reason_var"  '%s' "router_oom_kill"
            ;;
        *)
            printf -v "$verdict_var" '%s' "fail"
            printf -v "$reason_var"  '%s' "router_rc_nonzero"
            ;;
    esac
}
