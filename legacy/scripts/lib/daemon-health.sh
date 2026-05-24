# daemon-health.sh — Daemon health timeouts from policy (for sw-daemon.sh)
# Source from sw-daemon.sh. Requires SCRIPT_DIR, REPO_DIR, and policy.sh.
[[ -n "${_DAEMON_HEALTH_LOADED:-}" ]] && return 0
_DAEMON_HEALTH_LOADED=1

# Policy overrides when config/policy.json exists
[[ -f "${SCRIPT_DIR:-}/lib/policy.sh" ]] && source "${SCRIPT_DIR:-}/lib/policy.sh"

# Per-stage heartbeat timeout: policy .daemon.stage_timeouts.<stage> or .daemon.health_heartbeat_timeout
# Usage: daemon_health_timeout_for_stage <stage> [fallback]
daemon_health_timeout_for_stage() {
    local stage="${1:-unknown}"
    local fallback="${2:-120}"
    if type policy_get >/dev/null 2>&1; then
        local policy_val
        policy_val=$(policy_get ".daemon.stage_timeouts.$stage" "")
        if [[ -n "$policy_val" && "$policy_val" =~ ^[0-9]+$ ]]; then
            echo "$policy_val"
            return 0
        fi
        policy_val=$(policy_get ".daemon.health_heartbeat_timeout" "$fallback")
        [[ -n "$policy_val" && "$policy_val" =~ ^[0-9]+$ ]] && echo "$policy_val" || echo "$fallback"
    else
        case "$stage" in
            build)  echo "300" ;;
            test)   echo "180" ;;
            review|compound_quality) echo "180" ;;
            lint|format|intake|plan|design) echo "60" ;;
            *)      echo "$fallback" ;;
        esac
    fi
}
