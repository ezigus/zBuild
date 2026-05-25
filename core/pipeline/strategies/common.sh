#!/usr/bin/env bash
# core/pipeline/strategies/common.sh — shared helpers for strategy modules (issue #222)
# ADR-009 (platform-aware modularity), ADR-011 (pluggable orch backend)
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_STRATEGY_COMMON_LOADED:-}" ]] && return 0
_ZBUILD_STRATEGY_COMMON_LOADED=1

_ZBUILD_STRATEGIES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="${_ZBUILD_ROOT:-$(cd "${_ZBUILD_STRATEGIES_DIR}/../../.." && pwd)}"

# ─── _strategy_validate_stage ────────────────────────────────────────────────
# Allowlist: non-empty, no path-traversal sequences, no shell metacharacters.
# exit 0: valid; exit 2: invalid.
_strategy_validate_stage() {
    local stage="$1"
    [[ -z "$stage" ]] && return 2
    if [[ "$stage" == *".."* || "$stage" == "/"* || "$stage" =~ [[:space:]] || "$stage" == *$'\n'* ]]; then
        warn "strategy: invalid stage name: ${stage}" || true
        return 2
    fi
    return 0
}

# ─── _strategy_validate_platform ─────────────────────────────────────────────
# Allowlist: non-empty, ^[a-zA-Z0-9_-]{1,64}$.
# exit 0: valid; exit 2: invalid.
_strategy_validate_platform() {
    local platform="$1"
    [[ -z "$platform" ]] && return 2
    if [[ ! "$platform" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
        warn "strategy: invalid platform name: ${platform}" || true
        return 2
    fi
    return 0
}

# ─── _strategy_make_work_unit <plugin_dir> <stage> <state_file> <platform> ───
# Creates a self-contained executable shell script that calls plugin_hook_call.
# Validates stage and platform before baking into the script body.
# Prints the path of the temp file; caller is responsible for cleanup (rm -f).
# exit 0: success; exit 2: validation failure; exit 1: temp file creation failure.
_strategy_make_work_unit() {
    local plugin_dir="$1" stage="$2" state_file="$3" platform="${4:-generic}"

    _strategy_validate_stage "$stage"   || return 2
    _strategy_validate_platform "$platform" || return 2
    [[ -z "$plugin_dir" ]] && { warn "strategy: _strategy_make_work_unit: empty plugin_dir" || true; return 2; }

    local scratch_dir="${ZBUILD_ORCH_SCRATCH:-${HOME}/.zbuild/state/orch}"
    mkdir -p "$scratch_dir" 2>/dev/null && chmod 700 "$scratch_dir" 2>/dev/null || {
        warn "strategy: cannot create orch scratch dir: ${scratch_dir}" || true
        return 1
    }

    local wu
    # Note: no .sh suffix — macOS mktemp does not randomize names when a suffix follows XXXXXX.
    wu="$(mktemp "${scratch_dir}/wu-XXXXXX")" || {
        warn "strategy: mktemp failed for work unit" || true
        return 1
    }

    # Bake in fully-qualified, immutable paths at construction time.
    # Values are embedded as single-quoted literals to prevent re-expansion.
    # event-bus.sh is sourced so plugin_hook_call emits events to the shared
    # ZBUILD_EVENTS_JSONL / ZBUILD_EVENTS_DB (inherited env vars from runner).
    cat > "$wu" <<WORKUNIT
#!/usr/bin/env bash
set -euo pipefail
source '${_ZBUILD_ROOT}/scripts/lib/helpers.sh'
source '${_ZBUILD_ROOT}/core/event-bus/event-bus.sh'
source '${_ZBUILD_ROOT}/core/plugin-registry/registry.sh'
export ZBUILD_TARGET_PLATFORM='${platform}'
export ZBUILD_ROOT='${_ZBUILD_ROOT}'
plugin_hook_call '${plugin_dir}' run '${stage}' '${state_file}'
WORKUNIT

    chmod 700 "$wu"
    printf '%s\n' "$wu"
    return 0
}
