#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild plugin-registry — discovery, manifest validation, lifecycle       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# ADR-001 implementation. Plugins live in plugins/<kind>/<name>/ with a
# manifest.yaml and plugin.sh. The registry discovers them, validates manifests,
# applies a lockfile, and dispatches lifecycle hooks.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

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

# ─── yaml_get_list — extract a simple list value (inline or multi-line) ─────
# Usage: yaml_get_list <yaml_file> <key>
# Handles: key: [a, b, c]  OR  key:\n  - a\n  - b
yaml_get_list() {
    local file="$1"
    local key="$2"
    awk -v key="$key" '
    $0 ~ "^"key":[[:space:]]*\\[" {
        sub(/^[^[]*\[/, "")
        sub(/\].*$/, "")
        n = split($0, items, /,[[:space:]]*/)
        for (i = 1; i <= n; i++) {
            gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", items[i])
            if (items[i] != "") print items[i]
        }
        exit
    }
    $0 ~ "^"key":[[:space:]]*$" { in_list = 1; next }
    in_list && /^[[:space:]]*-[[:space:]]/ {
        item = $0
        gsub(/^[[:space:]]*-[[:space:]]*/, "", item)
        gsub(/[[:space:]]*#.*/, "", item)
        gsub(/^["'"'"']|["'"'"']$/, "", item)
        gsub(/[[:space:]]*$/, "", item)
        if (item != "") print item
    }
    in_list && /^[a-zA-Z_]/ { exit }
    ' "$file" 2>/dev/null
}

# ─── _yaml_get_requires_core_list — parse requires: → core: list ────────────
# Emits one core item per line. Structurally parses ONLY the `requires:` →
# `core:` sub-block — so a stray `- redaction` outside that block does NOT
# satisfy the membership check (closes the #294 bypass surface).
# Handles both inline `core: [a, b]` and multi-line:
#   requires:
#     core:
#       - a
#       - b
_yaml_get_requires_core_list() {
    local file="$1"
    awk '
        # Find requires: block at column 0
        /^requires:[[:space:]]*$/ { in_requires = 1; next }
        # Exit requires: block if we hit another top-level key
        in_requires && /^[a-zA-Z_]/ { in_requires = 0 }

        # Inside requires, find core:
        in_requires && /^[[:space:]]+core:[[:space:]]*\[/ {
            # Inline list: core: [a, b, c]
            line = $0
            sub(/^[^[]*\[/, "", line)
            sub(/\].*$/, "", line)
            n = split(line, items, /,[[:space:]]*/)
            for (i = 1; i <= n; i++) {
                gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", items[i])
                if (items[i] != "") print items[i]
            }
            in_requires = 0
            exit
        }
        in_requires && /^[[:space:]]+core:[[:space:]]*$/ {
            in_core = 1
            # Compute the indent depth of the `-` items: must be deeper than
            # the indent of `core:` itself.
            match($0, /^[[:space:]]+/)
            core_indent = RLENGTH
            next
        }
        # While inside core block, accept `<deeper-indent> - <item>` lines.
        in_core {
            if (match($0, /^[[:space:]]+-[[:space:]]+/)) {
                # Verify the indent is deeper than core: indent.
                indent_len = index($0, "-") - 1
                if (indent_len > core_indent) {
                    item = $0
                    gsub(/^[[:space:]]*-[[:space:]]*/, "", item)
                    gsub(/[[:space:]]*#.*/, "", item)
                    gsub(/^["'"'"']|["'"'"']$/, "", item)
                    gsub(/[[:space:]]*$/, "", item)
                    if (item != "") print item
                }
                next
            }
            # Any other content at the same or shallower indent ends the block.
            in_core = 0
        }
    ' "$file" 2>/dev/null
}

# ─── _required_hooks_for_kind — ADR-001 §"Required hooks per kind" ──────────
# Returns space-separated required hook names for the given plugin kind.
# Empty output = "no specifically required hooks" (still allow init/finalize/cleanup).
_required_hooks_for_kind() {
    case "$1" in
        agent)             echo "run" ;;
        tool)              echo "run" ;;
        recovery)          echo "classify act" ;;
        orchestrator)      echo "run" ;;
        claim-coordinator) echo "claim release heartbeat list_claims" ;;
        daemon)            echo "tick" ;;
        *)                 echo "" ;;
    esac
}

# ─── validate_manifest ──────────────────────────────────────────────────────
# Checks required fields, kind validity, kind-specific hook presence, and the
# ADR-004 redaction requirement for agent plugins. Returns 0 if valid, 1 if not.
# Issues #287, #294: expands beyond the original 4-field check.
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
    # Structural check via _yaml_get_requires_core_list — a `- redaction` line
    # outside `requires.core` no longer satisfies this (closes #294 bypass).
    if [[ "$kind" == "agent" ]]; then
        local core_items; core_items="$(_yaml_get_requires_core_list "$manifest")"
        if ! grep -Fxq "redaction" <<< "$core_items"; then
            error "validate_manifest($manifest): kind: agent plugins MUST declare 'redaction' inside requires.core (got: $(echo "$core_items" | tr '\n' ',' | sed 's/,$//'))"
            errors=$((errors + 1))
        fi
    fi

    # ─── #287/#294: hooks per kind ──────────────────────────────────────────
    # Every kind-required hook must be declared in the manifest's hooks: block.
    if [[ -n "$kind" ]]; then
        local required_hooks; required_hooks="$(_required_hooks_for_kind "$kind")"
        if [[ -n "$required_hooks" ]]; then
            local h
            for h in $required_hooks; do
                local fn; fn="$(yaml_get "$manifest" "hooks.$h" 2>/dev/null || true)"
                if [[ -z "$fn" ]]; then
                    error "validate_manifest($manifest): kind: $kind requires hook '$h' (declare under hooks: in the manifest)"
                    errors=$((errors + 1))
                fi
            done
        fi
    fi

    # ─── #287/#294: requires.core must be a YAML-structured list ────────────
    # Detect malformed `requires.core: redaction` (scalar instead of list).
    # Scoped to the requires: block so an unrelated `core:` line elsewhere
    # in the manifest doesn't falsely trigger.
    local has_requires
    has_requires="$(awk '/^requires:[[:space:]]*$/{print "y"; exit}' "$manifest")"
    if [[ "$has_requires" == "y" ]]; then
        local scalar_core
        scalar_core="$(awk '
            /^requires:[[:space:]]*$/ { in_req = 1; next }
            in_req && /^[a-zA-Z_]/ { in_req = 0 }
            in_req && /^[[:space:]]+core:[[:space:]]*[^[[:space:]]/ {
                # core: has non-whitespace, non-[ content on the same line.
                # Inline list is OK (handled by _yaml_get_requires_core_list)
                # but a bare scalar (e.g. `core: redaction`) is rejected.
                if ($0 !~ /^[[:space:]]+core:[[:space:]]*\[/) {
                    print "bad"
                    exit
                }
            }
        ' "$manifest")"
        if [[ "$scalar_core" == "bad" ]]; then
            error "validate_manifest($manifest): requires.core must be a YAML list (use 'core: [redaction, ...]' or '  - redaction')"
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

# ─── scan_plugin_outputs — fail-closed artifact-presence scanner (#288) ─────
# ADR-001 §Fail-closed scanner contract:
#   "If a plugin declares provides.artifact_type but no artifact exists at
#    outputs[].path after run completes with exit 0, the engine emits a
#    synthetic blocking finding."
#
# Arguments:
#   $1 — plugin_dir
#   $2 — state_file (so $state_dir / $artifacts_dir can substitute into paths)
#
# Returns:
#   0 if all declared outputs are present (or no outputs declared).
#   1 if any declared output is missing — and emits one
#      `plugin.artifact.missing` event per missing path.
#
# Path-template substitution (Phase 0.5): supports ${state_dir} and
# ${artifact_dir} / ${artifacts_dir}. Other env vars are best-effort:
# unsubstituted references remain literal (and will fail the existence check).
scan_plugin_outputs() {
    local plugin_dir="$1"
    local state_file="${2:-}"
    local manifest="$plugin_dir/manifest.yaml"

    # No manifest, no outputs to scan — silently succeed.
    [[ ! -f "$manifest" ]] && return 0

    local plugin_id; plugin_id="$(yaml_get "$manifest" "id" 2>/dev/null || true)"
    local kind; kind="$(yaml_get "$manifest" "kind" 2>/dev/null || true)"
    local artifact_type; artifact_type="$(yaml_get "$manifest" "provides.artifact_type" 2>/dev/null || true)"

    # If the plugin does not advertise a typed artifact, nothing to scan.
    [[ -z "$artifact_type" ]] && return 0

    # Compute substitution roots from state_file.
    local state_dir="" artifact_dir=""
    if [[ -n "$state_file" ]]; then
        state_dir="$(dirname "$state_file")"
        artifact_dir="${state_dir}/artifacts"
    fi

    # Pull outputs[].path entries from the manifest. yaml_get/yaml_get_list
    # don't model lists of objects, so grep the YAML directly. Format we
    # support (per ADR-001):
    #   outputs:
    #     - name: foo
    #       path: ${artifact_dir}/foo.json
    #       type: foo.json
    local paths
    paths="$(awk '
        /^outputs:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[a-zA-Z_]/ { in_block = 0 }
        in_block && /^[[:space:]]+path:[[:space:]]*/ {
            sub(/^[[:space:]]+path:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
        }
    ' "$manifest" 2>/dev/null)"

    [[ -z "$paths" ]] && return 0

    local missing=0
    local raw_path resolved
    while IFS= read -r raw_path; do
        [[ -z "$raw_path" ]] && continue
        resolved="$raw_path"
        # Phase 0.5 substitutions.
        resolved="${resolved//\$\{state_dir\}/$state_dir}"
        resolved="${resolved//\$\{artifact_dir\}/$artifact_dir}"
        resolved="${resolved//\$\{artifacts_dir\}/$artifact_dir}"

        if [[ ! -e "$resolved" ]]; then
            error "scan_plugin_outputs: plugin=$plugin_id declared output missing: $resolved (template: $raw_path)"
            emit_event "plugin.artifact.missing" \
                "plugin=$plugin_id" \
                "kind=$kind" \
                "artifact_type=$artifact_type" \
                "expected_path=$resolved" \
                "template=$raw_path"
            missing=$((missing + 1))
        fi
    done <<< "$paths"

    return $((missing > 0))
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

    # Pre-source tamper check (#290). Honors ZBUILD_STRICT_PLUGIN_LOCK.
    if ! verify_plugin_for_source "$manifest"; then
        emit_event "plugin.$hook_name.refused" "plugin=$plugin_id" "kind=$kind" "reason=lockfile-mismatch"
        return 1
    fi

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
        # #288: after a successful `run`, verify the plugin actually produced
        # the artifacts it declared. Absent evidence IS blocking evidence —
        # emit synthetic findings for each missing output and surface the
        # failure as a non-zero hook exit so the caller can react.
        if [[ "$hook_name" == "run" ]]; then
            # Per ADR-001 hook signature: $@ after shift 2 is (stage_id, state_file, ...).
            local state_file_arg="${2:-}"
            if ! scan_plugin_outputs "$plugin_dir" "$state_file_arg"; then
                emit_event "plugin.$hook_name.artifact_check_failed" \
                    "plugin=$plugin_id" "kind=$kind"
                return 1
            fi
        fi
        emit_event "plugin.$hook_name.complete" "plugin=$plugin_id" "kind=$kind"
    else
        emit_event "plugin.$hook_name.error" "plugin=$plugin_id" "kind=$kind" "rc=$rc"
    fi
    return $rc
}
