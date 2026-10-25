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
# #511 F2: `required: false` outputs are omitted, so a genuinely optional
# artifact is not flagged as a fail-closed contract violation when absent.
# (The test plugin's test_failures_summary was the original example; ADR-055 §9
# since made it `required: true`, so it is now enforced like any other output.)
_registry_output_path_rows() {
    local manifest="$1"
    [[ -f "$manifest" && -r "$manifest" ]] || return 2
    # Read by the shell, rule for rule as the awk it replaced (ADR-065 §5).
    local line v re in_block=0 cur_path="" cur_required="" cur_primary=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^outputs:[[:space:]]*$ ]]; then in_block=1; continue; fi
        (( in_block )) || continue
        if [[ "$line" =~ ^[a-zA-Z_] ]] || [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
            [[ -n "$cur_path" && "$cur_required" != "false" ]] && printf '%s\t%s\n' "$cur_path" "$cur_primary"
            cur_path=""; cur_required=""; cur_primary=""
            [[ "$line" =~ ^[a-zA-Z_] ]] && { in_block=0; continue; }
        fi
        for re in path required primary; do
            [[ "$line" =~ ^[[:space:]]+$re:[[:space:]]* ]] || continue
            v="${line:${#BASH_REMATCH[0]}}"
            if [[ "$v" == *#* ]]; then v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"; fi
            v="${v#[\"\']}"; v="${v%[\"\']}"
            case "$re" in
                path)     cur_path="$v" ;;
                required) cur_required="$v" ;;
                # Case-folded: a manifest writing `primary: True` must not read as
                # non-primary and so slip past the empty-artifact guard downstream.
                # `required` is deliberately NOT folded — a non-canonical value there
                # already fails closed (treated as required).
                primary)  cur_primary="${v,,}" ;;
            esac
            break
        done
    done < "$manifest"
    [[ -n "$cur_path" && "$cur_required" != "false" ]] && printf '%s\t%s\n' "$cur_path" "$cur_primary"
    return 0
}

# ─── _registry_resolve_output_path <raw_path> <state_dir> <artifact_dir> ─────
# Expands the Phase 0.5 substitution tokens plus any remaining ${VAR} from the
# work unit's exported env (the template's `as:` mapping, e.g.
# ZBUILD_REVIEW_LENS_ID). Indirect expansion only — never eval — so a manifest
# cannot inject a command. Bounded at 16 rounds; an unset var is left literal so
# the caller's check fails loudly rather than resolving to something plausible.
_registry_resolve_output_path() {
    local _rrop_o
    _registry_resolve_output_path_v _rrop_o "$@"
    printf '%s' "$_rrop_o"
}

# _registry_resolve_output_path_v <var> <raw> [state_dir] [artifact_dir] — the
# same into <var>, without the `$( )` every caller wrapped it in: one copy of
# the engine shell per output of every other plugin on each dispatch (ADR-065 §3).
_registry_resolve_output_path_v() {
    local _rrop_res="$2" _rrop_sd="${3:-}" _rrop_ad="${4:-}"
    local _rrop_var _rrop_n=0
    _rrop_res="${_rrop_res//\$\{state_dir\}/$_rrop_sd}"
    _rrop_res="${_rrop_res//\$\{artifact_dir\}/$_rrop_ad}"
    _rrop_res="${_rrop_res//\$\{artifacts_dir\}/$_rrop_ad}"
    while [[ $_rrop_n -lt 16 ]] && [[ "$_rrop_res" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        _rrop_var="${BASH_REMATCH[1]}"
        [[ -z "${!_rrop_var+x}" ]] && break
        _rrop_res="${_rrop_res//\$\{$_rrop_var\}/${!_rrop_var}}"
        _rrop_n=$((_rrop_n + 1))
    done
    printf -v "$1" '%s' "$_rrop_res"
}
