#!/usr/bin/env bash
# scripts/lib/doc-generate.sh — LLM-driven wiki page generator (DOC-D2).
#
# Source-only library (guard-loaded, no side-effects on source).
# Public API:
#   doc_generate_plugin  <id>   [plugins_root] [wiki_root] [mechanics_yaml] [template]
#   doc_generate_mechanic <name> [mechanics_yaml] [wiki_root] [plugins_root] [template]
#   doc_generate_page    <source_spec>  — CLI entrypoint: 'plugin:<id>' or 'mechanic:<name>'
#
# Behaviour:
#   1. Calls doc_gather_plugin_bundle / doc_gather_mechanic_bundle to get a key=value bundle.
#   2. Computes a SHA-256 source hash over the bundle's deterministic fields.
#   3. If a .hash sidecar exists and matches, skips the LLM call (short-circuit).
#   4. Builds a prompt embedding the doc-page template and decoded bundle fields.
#   5. Calls route_to_model T2.  If the response is exactly "NO_CHANGE", skips the write.
#   6. Otherwise writes the wiki page atomically via atomic_write.
#   7. In both write and NO_CHANGE cases, records/updates the source hash sidecar.
#
# Bash 4+. Source-only library; do not add `set -euo pipefail`.

[[ -n "${_ZBUILD_DOC_GENERATE_LOADED:-}" ]] && return 0
_ZBUILD_DOC_GENERATE_LOADED=1

_DOC_GENERATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DOC_GENERATE_ROOT="$(cd "$_DOC_GENERATE_DIR/../.." && pwd)"

# ─── Lazy-source router stack (same pattern as vision-init.sh) ──────────────
_doc_generate_ensure_router() {
    if ! declare -F route_to_model >/dev/null 2>&1; then
        source "$_DOC_GENERATE_ROOT/core/event-bus/event-bus.sh"
        source "$_DOC_GENERATE_ROOT/core/config/config.sh"
        zbuild_config_init
        source "$_DOC_GENERATE_ROOT/core/router/route.sh"
        if ! declare -F apply_scope_redaction >/dev/null 2>&1; then
            source "$_DOC_GENERATE_ROOT/core/redaction/redaction.sh" 2>/dev/null || true
        fi
    fi
}

# Lazy-source doc-gather (required for bundle functions).
_doc_generate_ensure_gather() {
    if ! declare -F doc_gather_plugin_bundle >/dev/null 2>&1; then
        source "$_DOC_GENERATE_DIR/doc-gather.sh"
    fi
}

# Lazy-source helpers (required for atomic_write).
_doc_generate_ensure_helpers() {
    if ! declare -F atomic_write >/dev/null 2>&1; then
        source "$_DOC_GENERATE_DIR/helpers.sh"
    fi
}

# _dgen_bundle_field <bundle> <key> — extract a single key=value field.
_dgen_bundle_field() {
    local bundle="$1" key="$2"
    printf '%s\n' "$bundle" | grep "^${key}=" | head -1 | sed "s/^${key}=//"
}

# _dgen_compute_hash <bundle> <page_type> — SHA-256 over deterministic bundle fields.
# Returns a 64-char hex string on stdout.
_dgen_compute_hash() {
    local bundle="$1" page_type="$2"
    local id_or_name="" summary="" usage="" source_b64="" defined_in="" tier_default="" kind="" version=""
    if [[ "$page_type" == "plugin" ]]; then
        id_or_name="$(_dgen_bundle_field "$bundle" "id")"
        kind="$(_dgen_bundle_field "$bundle" "kind")"
        version="$(_dgen_bundle_field "$bundle" "version")"
        tier_default="$(_dgen_bundle_field "$bundle" "tier_default")"
    else
        id_or_name="$(_dgen_bundle_field "$bundle" "name")"
        defined_in="$(_dgen_bundle_field "$bundle" "defined_in")"
    fi
    summary="$(_dgen_bundle_field "$bundle" "summary")"
    usage="$(_dgen_bundle_field "$bundle" "usage")"
    source_b64="$(_dgen_bundle_field "$bundle" "source")"

    # Concatenate deterministic fields, then hash.
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$page_type" "$id_or_name" "$kind" "$version" \
        "$tier_default" "$summary" "$usage" "$source_b64" \
        | shasum -a 256 | awk '{print $1}'
}

# _dgen_build_prompt <bundle> <page_type> <template_path> — build LLM prompt on stdout.
_dgen_build_prompt() {
    local bundle="$1" page_type="$2" template_path="$3"
    local template_content=""
    [[ -f "$template_path" ]] && template_content="$(<"$template_path")"

    local id_or_name="" summary="" usage="" source_b64="" source_decoded="" wiki_b64="" wiki_decoded=""
    local kind="" version="" tier_default="" defined_in=""

    if [[ "$page_type" == "plugin" ]]; then
        id_or_name="$(_dgen_bundle_field "$bundle" "id")"
        kind="$(_dgen_bundle_field "$bundle" "kind")"
        version="$(_dgen_bundle_field "$bundle" "version")"
        tier_default="$(_dgen_bundle_field "$bundle" "tier_default")"
    else
        id_or_name="$(_dgen_bundle_field "$bundle" "name")"
        defined_in="$(_dgen_bundle_field "$bundle" "defined_in")"
    fi

    summary="$(_dgen_bundle_field "$bundle" "summary")"
    usage="$(_dgen_bundle_field "$bundle" "usage")"
    source_b64="$(_dgen_bundle_field "$bundle" "source")"
    wiki_b64="$(_dgen_bundle_field "$bundle" "wiki_page")"

    source_decoded=""
    [[ -n "$source_b64" ]] && source_decoded="$(printf '%s' "$source_b64" | base64 -d 2>/dev/null)" || true
    wiki_decoded=""
    [[ -n "$wiki_b64" ]] && wiki_decoded="$(printf '%s' "$wiki_b64" | base64 -d 2>/dev/null)" || true

    cat <<PROMPT
You are a technical writer generating a zBuild documentation wiki page.
Use the template below to generate a conforming wiki page for the ${page_type} "${id_or_name}".

TEMPLATE (follow this structure exactly):
${template_content}

SOURCE DATA:
  type: ${page_type}
  name/id: ${id_or_name}
  summary: ${summary}
  usage: ${usage}
$(if [[ "$page_type" == "plugin" ]]; then
    printf '  kind: %s\n' "$kind"
    printf '  version: %s\n' "$version"
    printf '  tier_default: %s\n' "$tier_default"
else
    printf '  defined_in: %s\n' "${defined_in:-}"
fi)

SOURCE CODE:
${source_decoded}

EXISTING WIKI PAGE (empty if none):
${wiki_decoded}

OUTPUT INSTRUCTIONS:
- If the existing wiki page already conforms to the template and accurately reflects
  the source data above, output the single token: NO_CHANGE
- Otherwise, output ONLY the full updated wiki page markdown — no preamble, no triple
  backticks, no explanation. The first line must be a level-1 heading: # ${id_or_name}
PROMPT
}

# _doc_generate_page <bundle> <page_type> <out_path> [template_path]
# Core generation function. Used by both public entrypoints.
_doc_generate_page() {
    local bundle="$1" page_type="$2" out_path="$3"
    local template_path="${4:-$_DOC_GENERATE_ROOT/docs/templates/doc-page.md}"

    _doc_generate_ensure_helpers
    _doc_generate_ensure_router

    local hash_path="${out_path}.hash"

    # Compute source hash.
    local src_hash
    src_hash="$(_dgen_compute_hash "$bundle" "$page_type")"

    # Short-circuit: if hash sidecar exists and matches, skip LLM call.
    if [[ -f "$hash_path" ]]; then
        local existing_hash
        existing_hash="$(<"$hash_path")"
        existing_hash="${existing_hash%%[[:space:]]*}"   # trim whitespace
        if [[ "$existing_hash" == "$src_hash" ]]; then
            return 0
        fi
    fi

    # Build prompt.
    local prompt
    prompt="$(_dgen_build_prompt "$bundle" "$page_type" "$template_path")"

    # Call the LLM.
    local response rc=0
    response="$(route_to_model T2 "$prompt" --skip-precondition)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf 'doc_generate_page: route_to_model failed (rc=%d)\n' "$rc" >&2
        return 1
    fi

    # Trim leading/trailing whitespace from response to detect NO_CHANGE cleanly.
    local trimmed
    trimmed="$(printf '%s' "$response" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [[ "$trimmed" != "NO_CHANGE" ]]; then
        # Write the page atomically.
        mkdir -p "$(dirname "$out_path")"
        printf '%s\n' "$response" | atomic_write "$out_path"
    fi

    # Always write/update the hash sidecar.
    mkdir -p "$(dirname "$hash_path")"
    printf '%s\n' "$src_hash" | atomic_write "$hash_path"
}

# ─── Public entrypoints ──────────────────────────────────────────────────────

# doc_generate_plugin <id> [plugins_root] [wiki_root] [mechanics_yaml] [template]
doc_generate_plugin() {
    local id="$1"
    local plugins_root="${2:-$_DOC_GENERATE_ROOT/plugins}"
    local wiki_root="${3:-${ZBUILD_WIKI_ROOT:-$_DOC_GENERATE_ROOT/docs/wiki}}"
    local template="${5:-$_DOC_GENERATE_ROOT/docs/templates/doc-page.md}"

    _doc_generate_ensure_gather

    local bundle
    if ! bundle="$(doc_gather_plugin_bundle "$id" "$plugins_root" "$wiki_root")"; then
        printf 'doc_generate_plugin: failed to gather bundle for plugin: %s\n' "$id" >&2
        return 1
    fi

    local out_path="$wiki_root/plugins/${id}.md"
    _doc_generate_page "$bundle" "plugin" "$out_path" "$template"
}

# doc_generate_mechanic <name> [mechanics_yaml] [wiki_root] [plugins_root] [template]
doc_generate_mechanic() {
    local mech_name="$1"
    local mechanics_yaml="${2:-$_DOC_GENERATE_ROOT/config/mechanics.yaml}"
    local wiki_root="${3:-${ZBUILD_WIKI_ROOT:-$_DOC_GENERATE_ROOT/docs/wiki}}"
    local template="${5:-$_DOC_GENERATE_ROOT/docs/templates/doc-page.md}"

    _doc_generate_ensure_gather

    local bundle
    if ! bundle="$(doc_gather_mechanic_bundle "$mech_name" "$mechanics_yaml" "$wiki_root")"; then
        printf 'doc_generate_mechanic: failed to gather bundle for mechanic: %s\n' "$mech_name" >&2
        return 1
    fi

    local out_path="$wiki_root/mechanics/${mech_name}.md"
    _doc_generate_page "$bundle" "mechanic" "$out_path" "$template"
}

# doc_generate_page <source_spec> — CLI-level dispatcher.
# <source_spec> is 'plugin:<id>' or 'mechanic:<name>'.
doc_generate_page() {
    local spec="${1:-}"
    if [[ -z "$spec" ]]; then
        printf 'doc_generate_page: source spec required (plugin:<id> or mechanic:<name>)\n' >&2
        return 1
    fi

    local prefix="${spec%%:*}"
    local name="${spec#*:}"

    if [[ "$prefix" == "$spec" || -z "$name" ]]; then
        printf 'doc_generate_page: invalid source spec "%s" — use plugin:<id> or mechanic:<name>\n' "$spec" >&2
        return 1
    fi

    case "$prefix" in
        plugin)
            doc_generate_plugin "$name"
            ;;
        mechanic)
            doc_generate_mechanic "$name"
            ;;
        *)
            printf 'doc_generate_page: unknown source prefix "%s" — use plugin or mechanic\n' "$prefix" >&2
            return 1
            ;;
    esac
}
