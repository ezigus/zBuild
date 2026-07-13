#!/usr/bin/env bash
# scripts/lib/doc-gather.sh — pure-bash data-collection library for docs-automation.
#
# Collects structured bundles for a plugin id or mechanic name from:
#   - plugins/<kind>/<id>/manifest.yaml + plugin.sh   (plugin sources)
#   - config/mechanics.yaml                            (mechanic sources)
#   - docs/wiki/plugins/<id>.md or docs/wiki/mechanics/<name>.md (existing pages)
#
# Zero LLM calls. No side effects when sourced. All output on stdout.
#
# Public API:
#   doc_gather_plugin_ids  [plugins_root]
#   doc_gather_plugin_bundle  <id> [plugins_root] [wiki_root]
#   doc_gather_mechanic_ids  [mechanics_yaml]
#   doc_gather_mechanic_bundle  <name> [mechanics_yaml] [wiki_root]
#
# Bundle keys (key=value pairs, one per line):
#   Plugin:   id, name, kind, version, summary, usage, tier_default,
#             source (base64-encoded plugin.sh), wiki_page (base64-encoded or empty)
#   Mechanic: name, summary, usage, defined_in,
#             source (base64-encoded defined_in file), wiki_page (base64-encoded or empty)
#
# Bash 4+. Source-only library; do not add `set -euo pipefail`.

[[ -n "${_ZBUILD_DOC_GATHER_LOADED:-}" ]] && return 0
_ZBUILD_DOC_GATHER_LOADED=1

_DOC_GATHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve repo root: scripts/lib is two levels below repo root.
_DOC_GATHER_ROOT="$(cd "$_DOC_GATHER_DIR/../.." && pwd)"

# _dgather_yaml_scalar <file> <key> — top-level YAML scalar, trimmed (empty if absent).
_dgather_yaml_scalar() {
    local file="$1" key="$2"
    awk -v key="$key" '
        $0 ~ "^"key":[[:space:]]*" {
            sub("^"key":[[:space:]]*", "")
            # Strip inline comments
            sub(/[[:space:]]*#.*$/, "")
            # Strip surrounding quotes
            gsub(/^["'"'"']|["'"'"']$/, "")
            gsub(/\|[[:space:]]*$/, "")
            if ($0 != "") { print; exit }
        }
    ' "$file" 2>/dev/null
}

# _dgather_yaml_multiline <file> <key> — top-level block-scalar (| style) value.
_dgather_yaml_multiline() {
    local file="$1" key="$2"
    awk -v key="$key" '
        BEGIN { in_block = 0 }
        !in_block && $0 ~ "^"key":[[:space:]]*[|>]?[[:space:]]*$" {
            in_block = 1; next
        }
        in_block && /^[[:space:]]/ {
            sub(/^  /, "")   # strip two leading spaces
            print
            next
        }
        in_block { exit }
    ' "$file" 2>/dev/null
}

# _dgather_manifest_field <file> <key> — scalar value, falling back to block-scalar.
_dgather_manifest_field() {
    local file="$1" key="$2"
    local val
    val="$(_dgather_yaml_scalar "$file" "$key")"
    if [[ -z "$val" ]]; then
        val="$(_dgather_yaml_multiline "$file" "$key")"
    fi
    printf '%s' "$val"
}

# _dgather_find_manifest <id> <plugins_root> — path to the manifest whose id matches (rc=1 if none).
_dgather_find_manifest() {
    local id="$1" plugins_root="$2"
    local manifest
    # find uses -name to locate manifest.yaml, then checks that the id field matches
    while IFS= read -r manifest; do
        local found_id
        found_id="$(_dgather_yaml_scalar "$manifest" "id")"
        if [[ "$found_id" == "$id" ]]; then
            printf '%s' "$manifest"
            return 0
        fi
    done < <(find "$plugins_root" -name "manifest.yaml" 2>/dev/null | sort)
    return 1
}

# doc_gather_plugin_ids [plugins_root] — newline list of every plugin id.
doc_gather_plugin_ids() {
    local plugins_root="${1:-$_DOC_GATHER_ROOT/plugins}"
    local manifest
    while IFS= read -r manifest; do
        local id
        id="$(_dgather_yaml_scalar "$manifest" "id")"
        [[ -n "$id" ]] && printf '%s\n' "$id"
    done < <(find "$plugins_root" -name "manifest.yaml" 2>/dev/null | sort)
}

# doc_gather_plugin_bundle <id> [plugins_root] [wiki_root] — key=value bundle (rc=1 if id absent).
doc_gather_plugin_bundle() {
    local id="$1"
    local plugins_root="${2:-$_DOC_GATHER_ROOT/plugins}"
    local wiki_root="${3:-$_DOC_GATHER_ROOT/docs/wiki}"

    local manifest
    if ! manifest="$(_dgather_find_manifest "$id" "$plugins_root")"; then
        printf 'doc_gather_plugin_bundle: plugin id not found: %s\n' "$id" >&2
        return 1
    fi

    local plugin_dir
    plugin_dir="$(dirname "$manifest")"
    local plugin_sh="$plugin_dir/plugin.sh"

    local name kind version summary usage tier_default
    name="$(_dgather_manifest_field "$manifest" "name")"
    kind="$(_dgather_yaml_scalar "$manifest" "kind")"
    version="$(_dgather_yaml_scalar "$manifest" "version")"
    summary="$(_dgather_manifest_field "$manifest" "summary")"
    usage="$(_dgather_manifest_field "$manifest" "usage")"
    tier_default="$(_dgather_yaml_scalar "$manifest" "tier_default")"
    # tier_default may be nested under config:
    if [[ -z "$tier_default" ]]; then
        tier_default="$(awk '
            /^config:/ { in_cfg=1; next }
            in_cfg && /^[[:space:]]+tier_default:/ {
                sub(/^[[:space:]]+tier_default:[[:space:]]*/, "")
                print; exit
            }
            in_cfg && /^[a-zA-Z]/ { exit }
        ' "$manifest" 2>/dev/null)"
    fi

    local source_b64=""
    if [[ -f "$plugin_sh" ]]; then
        source_b64="$(base64 < "$plugin_sh" | tr -d '\n')"
    fi

    local wiki_page_b64=""
    local wiki_file="$wiki_root/plugins/${id}.md"
    if [[ -f "$wiki_file" ]]; then
        wiki_page_b64="$(base64 < "$wiki_file" | tr -d '\n')"
    fi

    printf 'id=%s\n'           "$id"
    printf 'name=%s\n'         "$name"
    printf 'kind=%s\n'         "$kind"
    printf 'version=%s\n'      "$version"
    printf 'summary=%s\n'      "$summary"
    printf 'usage=%s\n'        "$usage"
    printf 'tier_default=%s\n' "$tier_default"
    printf 'source=%s\n'       "$source_b64"
    printf 'wiki_page=%s\n'    "$wiki_page_b64"
}

# _dgather_mechanic_stanza <mechanics_yaml> <name> <field> — one field from one mechanic entry.
_dgather_mechanic_stanza() {
    local file="$1" mech_name="$2" field="$3"
    # shellcheck disable=SC1078,SC1079
    awk -v name="$mech_name" -v field="$field" '
        BEGIN { in_mech = 0; in_field = 0; found = 0 }
        # detect start of a mechanic entry by "  - name: <mech_name>"
        /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
            cur = $0
            sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", cur)
            sub(/[[:space:]]*#.*$/, "", cur)
            gsub(/^["'"'"']|["'"'"']$/, "", cur)
            if (cur == name) { in_mech = 1; in_field = 0 }
            else { in_mech = 0; in_field = 0 }
            next
        }
        in_mech && $0 ~ "^[[:space:]]+"field":[[:space:]]*" {
            # capture the field key indent so block content (deeper) can be told
            # apart from sibling keys at the SAME indent (#1444 over-capture fix).
            match($0, /^[[:space:]]+/); field_indent = RLENGTH
            val = $0
            sub(/^[[:space:]]+/, "", val)
            sub("^"field":[[:space:]]*", "", val)
            sub(/[[:space:]]*#.*$/, "", val)
            raw = val
            gsub(/^["'"'"']|["'"'"']$/, "", val)
            if (raw ~ /^[|>]/) {
                in_field = 1
                found = 1
                next
            }
            print val
            exit
        }
        # block-scalar continuation: only lines indented STRICTLY DEEPER than the
        # field key are content; a sibling key at the same indent ends the block.
        in_mech && in_field {
            if ($0 ~ /^[[:space:]]*$/) { print ""; next }
            match($0, /^[[:space:]]*/); this_indent = RLENGTH
            if (this_indent > field_indent) {
                print substr($0, field_indent + 3)
                next
            }
            exit
        }
        # new top-level mechanic or end of mechanics block ends stanza
        /^[a-zA-Z]/ { in_mech = 0; in_field = 0 }
    ' "$file" 2>/dev/null
}

# doc_gather_mechanic_ids [mechanics_yaml] — newline list of every mechanic name.
doc_gather_mechanic_ids() {
    local mechanics_yaml="${1:-$_DOC_GATHER_ROOT/config/mechanics.yaml}"
    [[ ! -f "$mechanics_yaml" ]] && return 0
    awk '
        /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
            val = $0
            sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", val)
            sub(/[[:space:]]*#.*$/, "", val)
            gsub(/^["\x27]|["\x27]$/, "", val)
            if (val != "") print val
        }
    ' "$mechanics_yaml" 2>/dev/null
}

# doc_gather_mechanic_bundle <name> [mechanics_yaml] [wiki_root] — key=value bundle (rc=1 if absent).
doc_gather_mechanic_bundle() {
    local mech_name="$1"
    local mechanics_yaml="${2:-$_DOC_GATHER_ROOT/config/mechanics.yaml}"
    local wiki_root="${3:-$_DOC_GATHER_ROOT/docs/wiki}"

    if [[ ! -f "$mechanics_yaml" ]]; then
        printf 'doc_gather_mechanic_bundle: mechanics file not found: %s\n' "$mechanics_yaml" >&2
        return 1
    fi

    # Verify the mechanic exists
    local found=0
    local n
    while IFS= read -r n; do
        [[ "$n" == "$mech_name" ]] && found=1 && break
    done < <(doc_gather_mechanic_ids "$mechanics_yaml")

    if [[ "$found" -eq 0 ]]; then
        printf 'doc_gather_mechanic_bundle: mechanic not found: %s\n' "$mech_name" >&2
        return 1
    fi

    local summary usage defined_in
    summary="$(_dgather_mechanic_stanza "$mechanics_yaml" "$mech_name" "summary")"
    usage="$(_dgather_mechanic_stanza "$mechanics_yaml" "$mech_name" "usage")"
    defined_in="$(_dgather_mechanic_stanza "$mechanics_yaml" "$mech_name" "defined_in")"

    local source_b64=""
    local defined_in_abs
    if [[ -n "$defined_in" ]]; then
        # defined_in is relative to repo root
        defined_in_abs="$_DOC_GATHER_ROOT/$defined_in"
        if [[ -f "$defined_in_abs" ]]; then
            source_b64="$(base64 < "$defined_in_abs" | tr -d '\n')"
        fi
    fi

    local wiki_page_b64=""
    local wiki_file="$wiki_root/mechanics/${mech_name}.md"
    if [[ -f "$wiki_file" ]]; then
        wiki_page_b64="$(base64 < "$wiki_file" | tr -d '\n')"
    fi

    printf 'name=%s\n'       "$mech_name"
    printf 'summary=%s\n'    "$summary"
    printf 'usage=%s\n'      "$usage"
    printf 'defined_in=%s\n' "$defined_in"
    printf 'source=%s\n'     "$source_b64"
    printf 'wiki_page=%s\n'  "$wiki_page_b64"
}
