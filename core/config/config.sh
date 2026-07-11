#!/usr/bin/env bash
# core/config/config.sh — Backend selection from .zbuild/config.yaml (ADR-011)
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_CONFIG_LOADED:-}" ]] && return 0
_ZBUILD_CONFIG_LOADED=1

# Compiled-in defaults — the zero-dependency built-ins
declare -A _ZBUILD_BACKEND_DEFAULTS=(
    [memory]="sqlite"
    [orchestrator]="bash-parallel"
    [cache]="local"
    [versioning]="initiative-count"
)

# Allowed backend values per capability
declare -A _ZBUILD_BACKEND_ALLOWED=(
    [memory]="sqlite ruflo"
    [orchestrator]="bash-parallel ruflo-hive"
    [cache]="local gh-actions-cache s3"
    [versioning]="initiative-count"
)

# _zbuild_config_file: Find the config file. Prints path or empty. Exit 0 if found, 1 if not.
_zbuild_config_file() {
    # 1. Explicit env override
    if [[ -n "${ZBUILD_CONFIG_FILE:-}" ]]; then
        if [[ "$ZBUILD_CONFIG_FILE" == "/dev/null" ]]; then
            return 1
        fi
        if [[ -f "$ZBUILD_CONFIG_FILE" ]]; then
            echo "$ZBUILD_CONFIG_FILE"
            return 0
        fi
        # Explicit override pointing to nonexistent file is an error
        warn "ZBUILD_CONFIG_FILE set but file not found: $ZBUILD_CONFIG_FILE" >&2
        return 1
    fi
    # 2. Project-local .zbuild/config.yaml
    local proj_root
    proj_root="$(zbuild_project_root 2>/dev/null)" || true
    if [[ -n "$proj_root" && -f "$proj_root/.zbuild/config.yaml" ]]; then
        echo "$proj_root/.zbuild/config.yaml"
        return 0
    fi
    # 3. User-global ~/.zbuild/config.yaml
    if [[ -f "${HOME}/.zbuild/config.yaml" ]]; then
        echo "${HOME}/.zbuild/config.yaml"
        return 0
    fi
    return 1
}

# zbuild_config_get_backend <capability>: returns configured backend name
# capability: memory | orchestrator | cache
zbuild_config_get_backend() {
    local cap="$1"
    # 1. Env override (e.g., ZBUILD_MEMORY_BACKEND)
    local env_var="ZBUILD_${cap^^}_BACKEND"
    if [[ -n "${!env_var:-}" ]]; then
        echo "${!env_var}"
        return 0
    fi
    # 2. Config file
    local cfg
    cfg="$(_zbuild_config_file)" || true
    if [[ -n "$cfg" && -f "$cfg" ]]; then
        local val
        val="$(yaml_get "$cfg" "backends.$cap" 2>/dev/null)" || true
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    fi
    # 3. Compiled-in default
    echo "${_ZBUILD_BACKEND_DEFAULTS[$cap]:-}"
}

# zbuild_config_get <section> <key>: returns value from per-backend config block
zbuild_config_get() {
    local section="$1" key="$2"
    local cfg
    cfg="$(_zbuild_config_file)" || true
    [[ -z "$cfg" || ! -f "$cfg" ]] && return 0
    yaml_get "$cfg" "${section}.${key}" 2>/dev/null || true
}

# zbuild_config_validate_backends: warn on configured-but-missing backend plugins
zbuild_config_validate_backends() {
    local cap backend default role
    for cap in memory orchestrator cache versioning; do
        backend="$(zbuild_config_get_backend "$cap")"
        default="${_ZBUILD_BACKEND_DEFAULTS[$cap]}"
        # Skip validation for default backends — no plugin needed (built-in)
        [[ "$backend" == "$default" ]] && continue
        # Check if plugin exists for this backend
        role="${cap}-backend"
        if ! find_plugin_for_role "$role" "$backend" >/dev/null 2>&1; then
            warn "backend.missing: ${cap}=${backend} configured but plugin not found" >&2
            emit_event "backend.missing" "role=$role" "requested=$backend" || true
        fi
    done
}

# zbuild_config_init: called at startup — parses config, logs source
zbuild_config_init() {
    local cfg
    cfg="$(_zbuild_config_file)" || true
    if [[ -n "$cfg" ]]; then
        if [[ -n "${ZBUILD_DEBUG:-}" ]]; then
            echo "[config] loaded from $cfg" >&2 || true
        fi
    fi
    # Validate non-default backends (warn only, never abort)
    zbuild_config_validate_backends || true
}
