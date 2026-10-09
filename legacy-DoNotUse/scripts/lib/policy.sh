# shellcheck shell=bash
# policy.sh — Load central policy from config/policy.json or ~/.shipwright/policy.json
# Source this to get POLICY_* vars (optional). Scripts can also jq config/policy.json directly.
# Usage: source "$SCRIPT_DIR/lib/policy.sh"   (after SCRIPT_DIR is set)
[[ -n "${POLICY_LOADED:-}" ]] && return 0
POLICY_LOADED=1

# Resolve repo root (caller may set REPO_DIR)
_REPO_DIR="${REPO_DIR:-}"
[[ -z "$_REPO_DIR" && -n "${SCRIPT_DIR:-}" ]] && _REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[[ -z "$_REPO_DIR" ]] && _REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"

_POLICY_FILE=""
[[ -n "$_REPO_DIR" && -f "$_REPO_DIR/config/policy.json" ]] && _POLICY_FILE="$_REPO_DIR/config/policy.json"
[[ -f "${HOME}/.shipwright/policy.json" ]] && _POLICY_FILE="${HOME}/.shipwright/policy.json"

# Export a single helper: policy_get <json_path> [default]
# e.g. policy_get ".daemon.poll_interval_seconds" 60
policy_get() {
    local path="$1"
    local default="${2:-}"
    if [[ -z "$_POLICY_FILE" || ! -f "$_POLICY_FILE" ]]; then
        echo "$default"
        return 0
    fi
    local val
    val=$(jq -r "${path} // \"\"" "$_POLICY_FILE" 2>/dev/null)
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# Central iteration ceiling — single source of truth for build-loop worst-case math.
# Reads .pipeline.retry_max_iterations from policy.json (default 20).
iteration_ceiling() {
    policy_get '.pipeline.retry_max_iterations' 20
}

# apply_iteration_ceiling <proposed> [source_label]
# Echoes the capped value. Emits an event when capping occurred so silent
# truncation is observable in events.jsonl.
apply_iteration_ceiling() {
    local proposed="${1:-0}"
    local source_label="${2:-unknown}"
    local ceiling
    ceiling=$(iteration_ceiling)
    if [[ "$proposed" -gt "$ceiling" ]]; then
        if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
            emit_event "iteration_ceiling_applied" \
                "source=$source_label" \
                "proposed=$proposed" \
                "ceiling=$ceiling" >/dev/null 2>&1 || true
        fi
        echo "$ceiling"
    else
        echo "$proposed"
    fi
}
