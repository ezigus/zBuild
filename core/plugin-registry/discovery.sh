#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugin-registry — directory scan, listing, lockfile pin + verification    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Split from registry.sh (#364). Owns discovery (`discover_plugins`,
# `list_plugins_table`, `find_plugin_for_role`) and the lockfile/tamper layer
# (`lockfile_write`, `lockfile_validate`, `verify_plugin_for_source`,
# `_hash_plugin_pair`). Depends on `yaml_get` / `validate_manifest` from
# manifest-validation.sh — sourced together via the registry.sh facade.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.

[[ -n "${_ZBUILD_REGISTRY_DISCOVERY_LOADED:-}" ]] && return 0
_ZBUILD_REGISTRY_DISCOVERY_LOADED=1

# Lockfile location
ZBUILD_LOCKFILE="${ZBUILD_LOCKFILE:-${HOME}/.zbuild/state/plugins.lock}"
ZBUILD_DISABLED_FILE="${ZBUILD_DISABLED_FILE:-${_ZBUILD_ROOT}/config/plugins.disabled}"

# ─── discover_plugins ───────────────────────────────────────────────────────
# Returns (stdout, one per line): <plugin_path>
discover_plugins() {
    local plugins_root="${1:-$_ZBUILD_ROOT/plugins}"
    if [[ ! -d "$plugins_root" ]]; then
        emit_event "registry.discovery" "plugins_root=$plugins_root" "count=0"
        return 0
    fi
    local disabled=()
    if [[ -f "$ZBUILD_DISABLED_FILE" ]]; then
        while IFS= read -r line; do
            line="${line%%#*}"  # strip comments
            line="${line//[[:space:]]/}"
            [[ -n "$line" ]] && disabled+=("$line")
        done < "$ZBUILD_DISABLED_FILE"
    fi

    local count=0
    find "$plugins_root" -maxdepth 3 -name 'manifest.yaml' -type f 2>/dev/null | while IFS= read -r manifest; do
        local plugin_dir; plugin_dir="$(dirname "$manifest")"
        local plugin_id; plugin_id="$(yaml_get "$manifest" "id")"
        # Check disabled list
        local is_disabled=0
        for d in "${disabled[@]}"; do
            [[ "$d" == "$plugin_id" ]] && is_disabled=1
        done
        if [[ "$is_disabled" -eq 1 ]]; then
            continue
        fi
        if validate_manifest "$manifest" >/dev/null 2>&1; then
            echo "$plugin_dir"
            count=$((count + 1))
        else
            warn "discover_plugins: skipping invalid manifest: $manifest"
        fi
    done
}

# ─── list_plugins_table ─────────────────────────────────────────────────────
# Human-readable listing for `zbuild plugin list`.
list_plugins_table() {
    local plugins_root="${1:-$_ZBUILD_ROOT/plugins}"
    local count=0
    discover_plugins "$plugins_root" | while IFS= read -r plugin_dir; do
        local manifest="$plugin_dir/manifest.yaml"
        local id name kind version
        id="$(yaml_get "$manifest" "id")"
        name="$(yaml_get "$manifest" "name")"
        kind="$(yaml_get "$manifest" "kind")"
        version="$(yaml_get "$manifest" "version")"
        printf "  %-20s %-12s %-10s %s\n" "$id" "$kind" "$version" "$name"
        count=$((count + 1))
    done
}

# ─── lockfile_write / lockfile_validate ─────────────────────────────────────
# Lockfile format (one record per line):
#   <plugin_id> <manifest_sha>:<plugin_sh_sha> <manifest_path>
#
# Issue #290: hashing only the manifest leaves a tampered plugin.sh with
# unchanged manifest passing verification — and the engine then `source`s the
# tampered file, giving an attacker code execution. We now hash both files
# and reverify before sourcing (see verify_plugin_for_source).
#
# Legacy single-hash records (pre-#290) are detected and treated as a
# mismatch with a clearer message so users know to regenerate.

# ─── _hash_plugin_pair — emit "<manifest_sha>:<plugin_sh_sha>" ──────────────
_hash_plugin_pair() {
    local manifest="$1"
    local plugin_sh; plugin_sh="$(dirname "$manifest")/plugin.sh"
    local manifest_sha; manifest_sha="$(shasum -a 256 "$manifest" | cut -d' ' -f1)"
    local plugin_sh_sha
    if [[ -f "$plugin_sh" ]]; then
        plugin_sh_sha="$(shasum -a 256 "$plugin_sh" | cut -d' ' -f1)"
    else
        # Plugin has no plugin.sh (e.g., manifest-only data plugin). Use a
        # sentinel sha so absence is recorded explicitly and any later
        # appearance of plugin.sh becomes a detected change.
        plugin_sh_sha="0000000000000000000000000000000000000000000000000000000000000000"
    fi
    printf '%s:%s\n' "$manifest_sha" "$plugin_sh_sha"
}

lockfile_write() {
    local plugins_root="${1:-$_ZBUILD_ROOT/plugins}"
    local lockfile="${2:-$ZBUILD_LOCKFILE}"
    mkdir -p "$(dirname "$lockfile")"
    : > "$lockfile.tmp"
    discover_plugins "$plugins_root" | sort | while IFS= read -r plugin_dir; do
        local manifest="$plugin_dir/manifest.yaml"
        local id; id="$(yaml_get "$manifest" "id")"
        local pair; pair="$(_hash_plugin_pair "$manifest")"
        echo "$id $pair $manifest"
    done > "$lockfile.tmp"
    mv "$lockfile.tmp" "$lockfile"
    emit_event "registry.lockfile.written" "lockfile=$lockfile"
}

lockfile_validate() {
    local lockfile="${1:-$ZBUILD_LOCKFILE}"
    if [[ ! -f "$lockfile" ]]; then
        return 0  # No lockfile yet; first run.
    fi
    local mismatches=0
    while IFS=' ' read -r id expected_pair manifest; do
        if [[ ! -f "$manifest" ]]; then
            warn "lockfile_validate: manifest missing for $id: $manifest"
            mismatches=$((mismatches + 1))
            continue
        fi
        # Detect legacy single-hash records (no colon → pre-#290 format).
        if [[ "$expected_pair" != *:* ]]; then
            warn "lockfile_validate: legacy single-hash record for $id; regenerate lockfile (\`zbuild plugin lock\`) to enable plugin.sh tamper detection (#290)"
            mismatches=$((mismatches + 1))
            continue
        fi
        local actual_pair; actual_pair="$(_hash_plugin_pair "$manifest")"
        if [[ "$actual_pair" != "$expected_pair" ]]; then
            local expected_manifest="${expected_pair%:*}"
            local expected_plugin_sh="${expected_pair#*:}"
            local actual_manifest="${actual_pair%:*}"
            local actual_plugin_sh="${actual_pair#*:}"
            if [[ "$actual_manifest" != "$expected_manifest" && "$actual_plugin_sh" != "$expected_plugin_sh" ]]; then
                warn "lockfile_validate: $id — BOTH manifest.yaml AND plugin.sh changed since lockfile"
            elif [[ "$actual_manifest" != "$expected_manifest" ]]; then
                warn "lockfile_validate: $id — manifest.yaml changed since lockfile"
            else
                warn "lockfile_validate: $id — plugin.sh changed since lockfile (possible tampering)"
            fi
            mismatches=$((mismatches + 1))
        fi
    done < "$lockfile"
    return $((mismatches > 0))
}

# ─── verify_plugin_for_source — pre-source tamper check (#290) ──────────────
# Returns 0 if plugin.sh is safe to source per the lockfile, 1 if tampered.
# When ZBUILD_STRICT_PLUGIN_LOCK=1, this is called from plugin_hook_call right
# before `source "$plugin_sh"`; mismatch refuses to source. When the env var
# is unset (default), behavior matches lockfile_validate: warn-only.
#
# If no lockfile entry exists for this plugin, returns 0 — the lockfile is
# the authority on what's pinned, and a brand-new plugin won't be there yet.
verify_plugin_for_source() {
    local manifest="$1"
    local lockfile="${2:-$ZBUILD_LOCKFILE}"
    [[ ! -f "$lockfile" ]] && return 0

    local id; id="$(yaml_get "$manifest" "id")"
    [[ -z "$id" ]] && return 0

    local expected_pair manifest_in_lock
    while IFS=' ' read -r lock_id pair lock_manifest; do
        if [[ "$lock_id" == "$id" ]]; then
            expected_pair="$pair"
            manifest_in_lock="$lock_manifest"
            break
        fi
    done < "$lockfile"

    # No entry — new plugin, no pin to enforce.
    [[ -z "${expected_pair:-}" ]] && return 0

    # Legacy single-hash record: insist on regeneration before enforcing.
    if [[ "$expected_pair" != *:* ]]; then
        warn "verify_plugin_for_source: $id has legacy single-hash lockfile entry; cannot verify plugin.sh (#290)"
        [[ "${ZBUILD_STRICT_PLUGIN_LOCK:-0}" == "1" ]] && return 1
        return 0
    fi

    local actual_pair; actual_pair="$(_hash_plugin_pair "$manifest")"
    if [[ "$actual_pair" != "$expected_pair" ]]; then
        emit_event "plugin.tamper.detected" "plugin=$id" "manifest=$manifest_in_lock"
        if [[ "${ZBUILD_STRICT_PLUGIN_LOCK:-0}" == "1" ]]; then
            error "verify_plugin_for_source: $id — file hash mismatch (lockfile: $expected_pair, actual: $actual_pair). plugin.sh or manifest.yaml has changed since lock; refusing to source under ZBUILD_STRICT_PLUGIN_LOCK=1."
            return 1
        fi
        warn "verify_plugin_for_source: $id — file hash mismatch (lockfile: $expected_pair, actual: $actual_pair). plugin.sh or manifest.yaml has changed since lock. Set ZBUILD_STRICT_PLUGIN_LOCK=1 to refuse to source on mismatch."
        return 0
    fi
    return 0
}

# ─── find_plugin_for_role ────────────────────────────────────────────────────
# Find a plugin directory providing the given role and backend alias.
# Usage: find_plugin_for_role <role> <backend_alias> [plugins_root]
# Output: prints plugin_dir on success; returns 1 if not found.
# Matches by: provides.role == <role> AND (id == <alias> OR provides.alias == <alias>)
find_plugin_for_role() {
    local role="$1"
    local alias="$2"
    local plugins_root="${3:-${ZBUILD_PLUGINS_ROOT:-${_ZBUILD_ROOT}/plugins}}"
    local plugin_dir manifest declared_role plugin_id declared_alias

    while IFS= read -r plugin_dir; do
        manifest="$plugin_dir/manifest.yaml"
        [[ ! -f "$manifest" ]] && continue
        declared_role="$(yaml_get "$manifest" "provides.role" 2>/dev/null || true)"
        [[ "$declared_role" != "$role" ]] && continue
        plugin_id="$(yaml_get "$manifest" "id" 2>/dev/null || true)"
        declared_alias="$(yaml_get "$manifest" "provides.alias" 2>/dev/null || true)"
        if [[ "$plugin_id" == "$alias" || "$declared_alias" == "$alias" ]]; then
            echo "$plugin_dir"
            return 0
        fi
    done < <(discover_plugins "$plugins_root" 2>/dev/null || true)
    return 1
}
