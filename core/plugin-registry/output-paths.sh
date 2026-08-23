#!/usr/bin/env bash
# core/plugin-registry/output-paths.sh — one answer to "where does this declared
# output live?" (#1809, ADR-058 C9)
#
# Extracted from scan_plugin_outputs so the fail-closed artifact scanner and the
# write-boundary classifier resolve outputs[].path through the SAME code. Two
# copies were byte-equivalent when written; the point of the extraction is that
# they cannot drift apart later — a boundary whose two halves disagree about
# where a declared output lives is not a boundary.
#
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.

[[ -n "${_ZBUILD_REGISTRY_OUTPUT_PATHS_LOADED:-}" ]] && return 0
_ZBUILD_REGISTRY_OUTPUT_PATHS_LOADED=1

# ─── _registry_output_path_rows <manifest> ───────────────────────────────────
# Emits one `path<TAB>primary` row per declared output. yaml_get/yaml_get_list
# don't model lists of objects, so the YAML is parsed directly. Shape (ADR-001):
#   outputs:
#     - name: foo
#       path: ${artifact_dir}/foo.json
# #511 F2: `required: false` outputs are omitted — the test plugin's
# test_failures_summary is intentionally ABSENT on a passing run, and flagging it
# would break the parity goldens.
_registry_output_path_rows() {
    local manifest="$1"
    awk '
        BEGIN { in_block = 0; cur_path = ""; cur_required = ""; cur_primary = "" }
        function flush() {
            if (cur_path != "" && cur_required != "false") {
                print cur_path "\t" cur_primary
            }
            cur_path = ""; cur_required = ""; cur_primary = ""
        }
        /^outputs:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[a-zA-Z_]/ { flush(); in_block = 0 }
        in_block && /^[[:space:]]*-[[:space:]]/ { flush() }
        in_block && /^[[:space:]]+path:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            cur_path = line
            next
        }
        in_block && /^[[:space:]]+required:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+required:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            cur_required = line
            next
        }
        in_block && /^[[:space:]]+primary:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+primary:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            # Case-folded: a manifest writing `primary: True` must not read as
            # non-primary and so slip past the empty-artifact guard downstream.
            # `required` is deliberately NOT folded — a non-canonical value there
            # already fails closed (treated as required).
            cur_primary = tolower(line)
            next
        }
        END { flush() }
    ' "$manifest" 2>/dev/null
}

# ─── _registry_resolve_output_path <raw_path> <state_dir> <artifact_dir> ─────
# Expands the Phase 0.5 substitution tokens plus any remaining ${VAR} from the
# work unit's exported env (the template's `as:` mapping, e.g.
# ZBUILD_REVIEW_LENS_ID). Indirect expansion only — never eval — so a manifest
# cannot inject a command. Bounded at 16 rounds; an unset var is left literal so
# the caller's check fails loudly rather than resolving to something plausible.
_registry_resolve_output_path() {
    local resolved="$1" state_dir="${2:-}" artifact_dir="${3:-}"
    local _var _expansions=0
    resolved="${resolved//\$\{state_dir\}/$state_dir}"
    resolved="${resolved//\$\{artifact_dir\}/$artifact_dir}"
    resolved="${resolved//\$\{artifacts_dir\}/$artifact_dir}"
    while [[ $_expansions -lt 16 ]] && [[ "$resolved" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        _var="${BASH_REMATCH[1]}"
        [[ -z "${!_var+x}" ]] && break
        resolved="${resolved//\$\{$_var\}/${!_var}}"
        _expansions=$((_expansions + 1))
    done
    printf '%s' "$resolved"
}
