#!/usr/bin/env bash
# scripts/lib/lint-verdict-classify.sh — #1708
#
# The manifests are the source of truth for what a plugin can put on its verdict
# channel; verdict_classify is the engine's reader. Nothing checked the two agree,
# so the table drifted five times (#775, #1208, #1219, #1532, #1687) and every
# drift was found the same way: a spurious pipeline.indicator.unknown_verdict in a
# dogfood run, then a one-line patch after the fact.
#
# This lint closes that loop at BUILD time. For every plugin manifest with a
# `primary: true` output it asserts:
#   1. `config.valid_verdicts` is declared (an absent key is a failure — an
#      explicit `[]` is how a plugin that writes no verdict says so); and
#   2. every declared verdict classifies to something other than `unknown`.
#
# The `*)` → unknown arm in verdict_classify stays as the RUNTIME backstop for
# undeclared or malformed values (a corrupt artifact, a target-repo-supplied
# string). This lint only means a SHIPPED plugin can no longer be the cause.
#
# Usage: bash scripts/lib/lint-verdict-classify.sh [plugins_root]
# Exit:  0 = all declared verdicts classify; 1 = at least one violation.
set -euo pipefail

_LVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LVC_ROOT="$(cd "$_LVC_DIR/../.." && pwd)"

PLUGINS_ROOT="${1:-$_LVC_ROOT/plugins}"

# Fail loudly on a bad scan root rather than reporting a vacuous pass over zero
# files — mirrors lint-model-names.sh.
if [[ ! -d "$PLUGINS_ROOT" ]]; then
    echo "lint-verdict-classify: plugins root not found: $PLUGINS_ROOT" >&2
    exit 1
fi

# shellcheck source=../../core/pipeline/verdict.sh
source "$_LVC_ROOT/core/pipeline/verdict.sh"

if ! declare -F verdict_classify >/dev/null 2>&1; then
    echo "lint-verdict-classify: verdict_classify not defined after sourcing core/pipeline/verdict.sh" >&2
    exit 1
fi

# ─── _lvc_has_primary <manifest> ─────────────────────────────────────────────
# True when the manifest declares an outputs[] entry with `primary: true`.
_lvc_has_primary() {
    awk '
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { in_out=0 }
        in_out && /^[[:space:]]+primary:[[:space:]]*true/ { found=1; exit }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

# ─── _lvc_verdicts_state <manifest> ──────────────────────────────────────────
# Echoes one of:
#   absent            — no valid_verdicts key anywhere in the manifest
#   empty             — declared as an explicit inline [] (or a key with no items)
#   list <v1> <v2> …  — declared block list
# Scoped to the `config:` block so an unrelated key elsewhere cannot satisfy it.
_lvc_verdicts_state() {
    awk '
        /^config:[[:space:]]*$/ { in_cfg=1; next }
        in_cfg && /^[a-zA-Z_]/  { in_cfg=0 }
        in_cfg && /^[[:space:]]*valid_verdicts:/ {
            found=1
            # Inline form: valid_verdicts: []  (or any inline scalar/flow value)
            line=$0
            sub(/^[[:space:]]*valid_verdicts:[[:space:]]*/, "", line)
            if (line ~ /^\[[[:space:]]*\]$/) { inline_empty=1 }
            else if (line != "") { inline_other=line }
            in_list=1
            next
        }
        # Items of the block list: "    - value"
        in_cfg && in_list && /^[[:space:]]+-[[:space:]]*[^[:space:]]/ {
            v=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*$/, "", v)      # strip trailing comment
            gsub(/[[:space:]]*$/, "", v)
            if (v != "") { vals[n++]=v }
            next
        }
        # A comment line inside the list does not end it.
        in_cfg && in_list && /^[[:space:]]*#/ { next }
        # Any other key at config-item depth ends the list.
        in_cfg && in_list && /^[[:space:]]+[^-[:space:]]/ { in_list=0 }
        END {
            if (!found) { print "absent"; exit }
            if (n > 0) {
                printf "list"
                for (i = 0; i < n; i++) printf " %s", vals[i]
                printf "\n"
                exit
            }
            if (inline_empty || inline_other == "") { print "empty"; exit }
            print "list " inline_other
        }
    ' "$1"
}

violations=0
checked=0

while IFS= read -r manifest; do
    _lvc_has_primary "$manifest" || continue
    checked=$((checked + 1))

    plugin_rel="${manifest#"$_LVC_ROOT"/}"
    state="$(_lvc_verdicts_state "$manifest")"

    case "$state" in
        absent)
            echo "✗ $plugin_rel: declares a 'primary: true' output but no config.valid_verdicts" >&2
            echo "    every plugin with a primary output must declare the verdicts it can write." >&2
            echo "    a plugin that writes none declares an explicit: valid_verdicts: []" >&2
            violations=$((violations + 1))
            ;;
        empty)
            : # explicit "writes no verdict" — nothing to classify
            ;;
        list*)
            for v in ${state#list }; do
                cls="$(verdict_classify "$v")"
                if [[ "$cls" == "unknown" ]]; then
                    echo "✗ $plugin_rel: declares verdict '$v', which verdict_classify does not classify" >&2
                    echo "    add it to core/pipeline/verdict.sh (pass | warn | fail) or correct the manifest." >&2
                    violations=$((violations + 1))
                fi
            done
            ;;
    esac
done < <(find "$PLUGINS_ROOT" -name manifest.yaml -type f | sort)

if [[ "$checked" -eq 0 ]]; then
    echo "lint-verdict-classify: no manifests with a 'primary: true' output found under $PLUGINS_ROOT" >&2
    echo "    a vacuous pass is not a pass — check the scan root." >&2
    exit 1
fi

if [[ "$violations" -gt 0 ]]; then
    echo "lint-verdict-classify: $violations violation(s) across $checked manifest(s)" >&2
    exit 1
fi

echo "lint-verdict-classify: $checked manifest(s) checked, all declared verdicts classify"
