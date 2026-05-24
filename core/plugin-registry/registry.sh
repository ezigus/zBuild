#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild plugin-registry — discovery, manifest validation, lifecycle       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# ADR-001 implementation. Plugins live in plugins/<kind>/<name>/ with a
# manifest.yaml and plugin.sh. The registry discovers them, validates manifests,
# applies a lockfile, and dispatches lifecycle hooks.

[[ -n "${_ZBUILD_REGISTRY_LOADED:-}" ]] && return 0
_ZBUILD_REGISTRY_LOADED=1

_ZBUILD_REGISTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_ZBUILD_REGISTRY_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"

# ─── Valid plugin kinds ─────────────────────────────────────────────────────
ZBUILD_PLUGIN_KINDS=(agent tool recovery orchestrator claim-coordinator daemon)

# Lockfile location
ZBUILD_LOCKFILE="${ZBUILD_LOCKFILE:-${HOME}/.zbuild/state/plugins.lock}"
ZBUILD_DISABLED_FILE="${ZBUILD_DISABLED_FILE:-${_ZBUILD_ROOT}/config/plugins.disabled}"

# ─── yaml_get — minimal YAML reader (we control the schema; no full parser) ─
# Usage: yaml_get <yaml_file> <dotted_key>
# Supports: top-level scalars, single-level nested (e.g., hooks.init).
# Lists / multi-line scalars handled by yaml_get_list.
yaml_get() {
    local file="$1"
    local key="$2"
    awk -v key="$key" '
    BEGIN { split(key, parts, /\./); want = parts[1]; subwant = parts[2] }
    /^[a-zA-Z_][a-zA-Z0-9_-]*:/ {
        # Top-level key
        gsub(/:.*/, "", $0)
        if (subwant == "" && $0 == want) {
            # Get value after colon on same line
            getline line
            # Re-read: need value from original line
        }
    }
    ' "$file" 2>/dev/null
    # Simpler: use grep + sed
    local pattern
    if [[ "$key" == *.* ]]; then
        # Nested key like hooks.init: find "<parent>:" then indented "<child>:"
        local parent="${key%.*}"
        local child="${key#*.}"
        awk -v parent="$parent" -v child="$child" '
        $0 ~ "^"parent":" { in_block = 1; next }
        in_block && /^[a-zA-Z_]/ { in_block = 0 }
        in_block && $0 ~ "^[[:space:]]+"child":" {
            sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
        ' "$file" 2>/dev/null
    else
        # Top-level scalar
        awk -v key="$key" '
        $0 ~ "^"key":" {
            sub(/^[^:]+:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
        ' "$file" 2>/dev/null
    fi
}

# ─── validate_manifest ──────────────────────────────────────────────────────
# Checks required fields and kind validity. Returns 0 if valid, 1 if not.
validate_manifest() {
    local manifest="$1"
    local errors=0

    if [[ ! -f "$manifest" ]]; then
        error "validate_manifest: file not found: $manifest"
        return 1
    fi

    for field in id name kind version; do
        local val; val="$(yaml_get "$manifest" "$field")"
        if [[ -z "$val" ]]; then
            error "validate_manifest($manifest): missing required field: $field"
            errors=$((errors + 1))
        fi
    done

    local kind; kind="$(yaml_get "$manifest" "kind")"
    if [[ -n "$kind" ]]; then
        local valid=0
        for k in "${ZBUILD_PLUGIN_KINDS[@]}"; do
            [[ "$k" == "$kind" ]] && valid=1
        done
        if [[ "$valid" -eq 0 ]]; then
            error "validate_manifest($manifest): invalid kind: $kind (expected one of: ${ZBUILD_PLUGIN_KINDS[*]})"
            errors=$((errors + 1))
        fi
    fi

    # kind: agent plugins MUST declare requires.core includes redaction (ADR-004 enforcement)
    if [[ "$kind" == "agent" ]]; then
        if ! grep -qE '^\s+-\s+redaction\b' "$manifest"; then
            error "validate_manifest($manifest): kind: agent plugins MUST declare 'requires.core: [redaction, ...]'"
            errors=$((errors + 1))
        fi
    fi

    return $((errors > 0))
}

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
lockfile_write() {
    local plugins_root="${1:-$_ZBUILD_ROOT/plugins}"
    local lockfile="${2:-$ZBUILD_LOCKFILE}"
    mkdir -p "$(dirname "$lockfile")"
    : > "$lockfile.tmp"
    discover_plugins "$plugins_root" | sort | while IFS= read -r plugin_dir; do
        local manifest="$plugin_dir/manifest.yaml"
        local id; id="$(yaml_get "$manifest" "id")"
        local hash; hash="$(shasum -a 256 "$manifest" | cut -d' ' -f1)"
        echo "$id $hash $manifest"
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
    while IFS=' ' read -r id expected_hash manifest; do
        if [[ ! -f "$manifest" ]]; then
            warn "lockfile_validate: manifest missing for $id: $manifest"
            mismatches=$((mismatches + 1))
            continue
        fi
        local actual_hash; actual_hash="$(shasum -a 256 "$manifest" | cut -d' ' -f1)"
        if [[ "$actual_hash" != "$expected_hash" ]]; then
            warn "lockfile_validate: hash mismatch for $id (lockfile=$expected_hash, actual=$actual_hash)"
            mismatches=$((mismatches + 1))
        fi
    done < "$lockfile"
    return $((mismatches > 0))
}

# ─── plugin_hook_call ───────────────────────────────────────────────────────
# Source the plugin's plugin.sh and call a lifecycle hook by name.
# Plugin functions are isolated by sub-shell to prevent namespace pollution.
plugin_hook_call() {
    local plugin_dir="$1"
    local hook_name="$2"   # init | run | finalize | cleanup (or kind-specific)
    shift 2
    local manifest="$plugin_dir/manifest.yaml"
    local plugin_sh="$plugin_dir/plugin.sh"

    if [[ ! -f "$plugin_sh" ]]; then
        error "plugin_hook_call: plugin.sh missing: $plugin_sh"
        return 1
    fi

    local hook_fn; hook_fn="$(yaml_get "$manifest" "hooks.$hook_name")"
    if [[ -z "$hook_fn" ]]; then
        # No-op for unimplemented optional hooks
        return 0
    fi

    local plugin_id; plugin_id="$(yaml_get "$manifest" "id")"
    local kind; kind="$(yaml_get "$manifest" "kind")"

    emit_event "plugin.$hook_name.start" "plugin=$plugin_id" "kind=$kind"

    # Run in a subshell to isolate plugin's variables/functions
    (
        # shellcheck disable=SC1090
        source "$plugin_sh"
        if declare -F "$hook_fn" >/dev/null 2>&1; then
            "$hook_fn" "$@"
        else
            echo "plugin_hook_call: function $hook_fn not defined in $plugin_sh" >&2
            exit 1
        fi
    )
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        emit_event "plugin.$hook_name.complete" "plugin=$plugin_id" "kind=$kind"
    else
        emit_event "plugin.$hook_name.error" "plugin=$plugin_id" "kind=$kind" "rc=$rc"
    fi
    return $rc
}
