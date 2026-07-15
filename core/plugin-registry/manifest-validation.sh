#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugin-registry — manifest YAML parsing + schema/identity/hook validation ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Split from registry.sh (#364). Owns the manifest layer: minimal YAML readers
# (yaml_get / yaml_get_list / _yaml_get_requires_core_list), the kind table
# (ZBUILD_PLUGIN_KINDS / _required_hooks_for_kind), and validate_manifest.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.

[[ -n "${_ZBUILD_REGISTRY_MANIFEST_LOADED:-}" ]] && return 0
_ZBUILD_REGISTRY_MANIFEST_LOADED=1

# ─── Valid plugin kinds ─────────────────────────────────────────────────────
# `persona` (#1304) is a DATA-only kind: identity metadata (role + perspective),
# no plugin.sh and no hooks. See _required_hooks_for_kind (returns "" for it) and
# the persona.role requirement in validate_manifest.
ZBUILD_PLUGIN_KINDS=(agent tool recovery orchestrator claim-coordinator daemon persona)

# ─── yaml_get — minimal YAML reader (we control the schema; no full parser) ─
# Usage: yaml_get <yaml_file> <dotted_key>
# Supports: top-level scalars, single-level nested (e.g., hooks.init).
# Lists / multi-line scalars handled by yaml_get_list.
yaml_get() {
    local file="$1"
    local key="$2"
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

    # kind: persona plugins (#1304) are DATA — a professional identity, no
    # plugin.sh and no hooks. They MUST declare a non-empty persona.role: the
    # noun phrase that slots into the stage/lens framing ("You are {role} …").
    # kind:persona is intentionally exempt from the kind:agent redaction check
    # above — persona text is redaction-covered at injection by the router
    # (ADR-043), not by the plugin declaring requires.core.redaction.
    if [[ "$kind" == "persona" ]]; then
        local persona_role; persona_role="$(yaml_get "$manifest" "persona.role")"
        if [[ -z "$persona_role" ]]; then
            error "validate_manifest($manifest): kind: persona requires a non-empty 'persona.role' (the noun phrase for 'You are {role} for the target project.')"
            errors=$((errors + 1))
        fi
    fi

    # ─── #287/#294: hooks per kind ──────────────────────────────────────────
    # Every kind-required hook must be declared in the manifest's hooks: block.
    # Backend plugins (those declaring `provides.role`) are invoked through
    # contract layers (cache_pull, memory_put, etc.) — not plugin_hook_call —
    # so they don't need lifecycle hooks. The check skips when role is set.
    if [[ -n "$kind" ]]; then
        local provides_role; provides_role="$(yaml_get "$manifest" "provides.role" 2>/dev/null || true)"
        if [[ -z "$provides_role" ]]; then
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

    # ─── Optional doc fields: summary + usage ────────────────────────────────
    # If declared, each must be a non-empty string. Absent = fine; present-but-
    # empty = misconfiguration (declared doc field with no content).
    #
    # Presence + value are resolved in ONE awk pass with a LITERAL, TOP-LEVEL
    # match: `index($0, key":")==1` is true only when the line begins with the
    # exact key at column 0 — so it never matches an indented/nested key or a
    # line inside a block scalar, and (being index(), not a regex) the field
    # name is never interpreted as a pattern. Emits OK / EMPTY / (nothing).
    local doc_field doc_state
    for doc_field in summary usage; do
        doc_state="$(awk -v k="$doc_field" '
            index($0, k":") == 1 {
                v = $0
                sub(/^[^:]*:[[:space:]]*/, "", v)   # strip "key:" + leading ws
                sub(/[[:space:]]*#.*/, "", v)        # strip trailing comment
                gsub(/^["'"'"']|["'"'"']$/, "", v)   # strip surrounding quotes
                print (v == "" ? "EMPTY" : "OK")
                exit
            }
        ' "$manifest" 2>/dev/null)"
        if [[ "$doc_state" == "EMPTY" ]]; then
            error "validate_manifest($manifest): '$doc_field' is declared but empty (must be a non-empty string)"
            errors=$((errors + 1))
        fi
    done

    return $((errors > 0))
}
