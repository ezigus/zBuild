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
#   _router_rc_classify <rc> <verdict_var> <reason_var>
#     - On rc=0: verdict="" reason=""  (caller treats as success)
#     - On rc=124: verdict="error" reason="router_timeout"
#     - On rc=137: verdict="error" reason="router_oom_kill"  (SIGKILL by OOM)
#     - On other rc>0: verdict="fail" reason="router_rc_nonzero"

# Idempotent source guard.
if [[ "${_ZBUILD_ROUTER_RC_CLASSIFY_LOADED:-}" == "1" ]]; then
    return 0
fi
_ZBUILD_ROUTER_RC_CLASSIFY_LOADED=1

_router_rc_classify() {
    local rc="$1" verdict_var="$2" reason_var="$3"
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
