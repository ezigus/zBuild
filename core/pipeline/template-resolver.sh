#!/usr/bin/env bash
# core/pipeline/template-resolver.sh — Per-repo template override loader (issue #653)
# ADR-016 (full-replace overlay). Sourced library; no set -euo pipefail.


# #2010: zbuild_engine_tmp names where engine code writes temp files.
# Lazy-sourced, same pattern lifecycle.sh uses for stage-scratch.sh: this
# file is sourced from several entry points and cannot assume helpers.sh
# arrived first. helpers.sh sources only compat.sh, so there is no cycle.
if ! declare -F zbuild_engine_tmp >/dev/null 2>&1; then
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib" && pwd)/helpers.sh" 2>/dev/null || true
fi

[[ -n "${_ZBUILD_TEMPLATE_RESOLVER_LOADED:-}" ]] && return 0
_ZBUILD_TEMPLATE_RESOLVER_LOADED=1

_TEMPLATE_RESOLVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TEMPLATE_RESOLVER_ROOT="$(cd "$_TEMPLATE_RESOLVER_DIR/../.." && pwd)"

# resolve_template_file <id> <repo_root>
#
# Returns the path to the effective template file via stdout:
#   - If <repo_root>/.zbuild/templates/<id>.yaml exists: validate extends:,
#     merge stages: and stage_definitions: over the base (ADR-016 full-replace),
#     write to a temp file, and print that path.
#   - Otherwise: print config/templates/<id>.yaml (shipped path, no merge).
# Exits 1 with a structured error if extends: is missing or the base is absent.
resolve_template_file() {
    local id="$1"
    local repo_root="${2:-$_TEMPLATE_RESOLVER_ROOT}"

    local per_repo_file="$repo_root/.zbuild/templates/${id}.yaml"
    local shipped_file="$_TEMPLATE_RESOLVER_ROOT/config/templates/${id}.yaml"

    if [[ ! -f "$per_repo_file" ]]; then
        echo "$shipped_file"
        return 0
    fi

    local extends_id
    extends_id="$(awk '/^extends:[[:space:]]/ { v=$0; sub(/^extends:[[:space:]]+/, "", v); sub(/[[:space:]]*$/, "", v); if (v != "" && v != "null") { print v; exit } }' "$per_repo_file")"

    if [[ -z "$extends_id" ]]; then
        echo "template-resolver: per-repo template '${id}' is missing required 'extends:' key" >&2
        return 1
    fi

    local base_file="$_TEMPLATE_RESOLVER_ROOT/config/templates/${extends_id}.yaml"
    if [[ ! -f "$base_file" ]]; then
        echo "template-resolver: per-repo template '${id}' extends '${extends_id}' but config/templates/${extends_id}.yaml does not exist" >&2
        return 1
    fi

    # Write merged file to temp dir (TEST_TEMP_DIR in tests, mktemp in production).
    local merged_file
    if [[ -n "${TEST_TEMP_DIR:-}" ]]; then
        merged_file="${TEST_TEMP_DIR}/zbuild-tpl-${id}-$$.yaml"
    else
        # macOS/BSD mktemp requires XXXXXX at end (no trailing extension).
        # Mirrors the ${TMPDIR:-/tmp}/name.XXXXXX pattern used elsewhere.
        merged_file="$(mktemp "$(zbuild_engine_tmp)/zbuild-tpl.XXXXXX")"
    fi

    # ADR-016 lock 1 is "full replace: there is no field-level merge with the
    # shipped file." A NEW-shape override (ADR-027: top-level `flow:` plus
    # per-stage sections) already IS the whole template, so full replace means
    # using it verbatim.
    #
    # Without this branch the awk below — which knows only the OLD shape's
    # `stages:`/`stage_definitions:` blocks — copies the base wholesale and
    # appends nothing, because a new-shape override has neither block. The
    # override is discarded, the BASE template runs, and nothing says so. The
    # implementation contradicted the ADR for every new-shape override; the spec
    # wins (CLAUDE.md).
    #
    # `extends:` stays required and its base still has to exist (locks 2 and 3):
    # those are about declaring lineage, not about merging fields.
    if awk 'BEGIN{rc=1} /^flow:[[:space:]]*$/ {rc=0; exit} /^flow:[[:space:]]*\[/ {rc=0; exit} END{exit rc}' "$per_repo_file"; then
        cp "$per_repo_file" "$merged_file"
        echo "$merged_file"
        return 0
    fi

    # OLD shape: emit base file minus its stages:/stage_definitions: blocks,
    # then append the per-repo stages:/stage_definitions: blocks wholesale.
    awk '
        /^stages:[[:space:]]*$/ { in_stages=1; next }
        /^stage_definitions:[[:space:]]*$/ { in_defs=1; next }
        in_stages && /^[a-zA-Z_]/ { in_stages=0 }
        in_defs   && /^[a-zA-Z_]/ { in_defs=0 }
        in_stages || in_defs { next }
        { print }
    ' "$base_file" > "$merged_file"

    # Extract and append stages: block from per-repo file.
    awk '
        /^stages:[[:space:]]*$/ { in_block=1; print; next }
        in_block && /^[a-zA-Z_]/ { in_block=0 }
        in_block { print }
    ' "$per_repo_file" >> "$merged_file"

    # Extract and append stage_definitions: block from per-repo file.
    awk '
        /^stage_definitions:[[:space:]]*$/ { in_block=1; print; next }
        in_block && /^[a-zA-Z_]/ { in_block=0 }
        in_block { print }
    ' "$per_repo_file" >> "$merged_file"

    echo "$merged_file"
    return 0
}
