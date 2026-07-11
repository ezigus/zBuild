#!/usr/bin/env bash
# scripts/lib/version.sh — versioning engine seam (ADR-011 + ADR-048).
#
# The versioning SCHEME is pluggable data, not baked into core: the engine reads
# the selected `versioning` backend (`zbuild_config_get_backend versioning`) and
# dispatches to its strategy. The default built-in strategy is `initiative-count`
# (4-part A.B.C.D). A repo owner overrides it via ZBUILD_VERSIONING_BACKEND / the
# `.zbuild/config.yaml` `backends.versioning` key / a `versioning-backend` plugin.
#
# Sourced library: inherits caller's pipefail; no set -euo pipefail here.

[[ -n "${_ZBUILD_VERSION_SEAM_LOADED:-}" ]] && return 0
_ZBUILD_VERSION_SEAM_LOADED=1

_ZBUILD_VERSION_SEAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Emit a fail-loud message to stderr (uses helpers' `error` when available).
_rv_err() {
    if declare -F error >/dev/null 2>&1; then error "$*"; else echo "$*" >&2; fi
}

# ─── resolve_repo_version ───────────────────────────────────────────────────
# Select the versioning backend, source its strategy, and call its `<backend>_version`
# entrypoint. Fails loud (rc=1) on an unknown/absent configured backend, mirroring
# ADR-011 `backend.missing`. Prints the resolved version on stdout.
resolve_repo_version() {
    local backend
    if declare -F zbuild_config_get_backend >/dev/null 2>&1; then
        backend="$(zbuild_config_get_backend "versioning" 2>/dev/null)" || true
    fi
    backend="${backend:-initiative-count}"

    # Built-in default strategy — source directly.
    if [[ "$backend" == "initiative-count" ]]; then
        # shellcheck source=versioning/initiative-count.sh
        source "$_ZBUILD_VERSION_SEAM_DIR/versioning/initiative-count.sh"
    else
        # Non-default: locate the plugin via the registry (versioning-backend role).
        local plugin_dir=""
        if declare -F find_plugin_for_role >/dev/null 2>&1; then
            plugin_dir="$(find_plugin_for_role "versioning-backend" "$backend" 2>/dev/null)" || true
        fi
        if [[ -n "$plugin_dir" && -f "${plugin_dir}/plugin.sh" ]]; then
            # shellcheck disable=SC1090
            source "${plugin_dir}/plugin.sh"
        else
            _rv_err "backend.missing: versioning=${backend} configured but plugin not found"
            if declare -F emit_event >/dev/null 2>&1; then
                emit_event "backend.missing" "role=versioning-backend" "requested=$backend" || true
            fi
            return 1
        fi
    fi

    # Every versioning backend must expose `<backend>_version`.
    local entry="${backend}_version"
    if ! declare -F "$entry" >/dev/null 2>&1; then
        _rv_err "versioning backend '${backend}' did not define ${entry}"
        return 1
    fi

    "$entry"
}
