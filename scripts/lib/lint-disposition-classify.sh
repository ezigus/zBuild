#!/usr/bin/env bash
# scripts/lib/lint-disposition-classify.sh — #1959 (shipped in #2129)
#
# The manifest is the source of truth for what a plugin can put on its
# failures[] channel; scripts/lib/acceptance-disposition.sh is the engine's
# reader. Nothing checked the two agree, so the table drifted five times
# (#1583, #1585, #1686, #1670, #2097) and every drift was found the same way:
# a run halted `terminal` on a class nobody had named, then a one-line patch.
#
# For every plugin whose plugin.sh writes failures[] (`failures+=(`) it asserts:
#   1. `config.valid_failure_classes` is declared (absent is a failure); and
#   2. every declared class maps to a disposition.
# Mirrors lint-verdict-classify.sh (#1708).
#
# Usage: bash scripts/lib/lint-disposition-classify.sh [plugins_root]
# Exit:  0 = every declared class classifies; 1 = at least one violation.
set -euo pipefail

_LDC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LDC_ROOT="$(cd "$_LDC_DIR/../.." && pwd)"
PLUGINS_ROOT="${1:-$_LDC_ROOT/plugins}"

if [[ ! -d "$PLUGINS_ROOT" ]]; then
    echo "lint-disposition-classify: plugins root not found: $PLUGINS_ROOT" >&2
    exit 1
fi

# shellcheck source=./acceptance-disposition.sh
source "$_LDC_DIR/acceptance-disposition.sh"

# _ldc_classes <manifest> → "absent" | "list <c1> <c2> …" (block list under config:)
_ldc_classes() {
    awk '
        /^config:[[:space:]]*$/ { in_cfg=1; next }
        in_cfg && /^[a-zA-Z_]/  { in_cfg=0 }
        in_cfg && /^[[:space:]]*valid_failure_classes:/ { found=1; in_list=1; next }
        in_cfg && in_list && /^[[:space:]]+-[[:space:]]*[^[:space:]]/ {
            v=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); sub(/[[:space:]]*#.*$/, "", v)
            gsub(/[[:space:]]*$/, "", v); if (v != "") vals[n++]=v; next
        }
        in_cfg && in_list && /^[[:space:]]*#/ { next }
        in_cfg && in_list && /^[[:space:]]+[^-[:space:]]/ { in_list=0 }
        END {
            if (!found) { print "absent"; exit }
            printf "list"; for (i = 0; i < n; i++) printf " %s", vals[i]; printf "\n"
        }
    ' "$1"
}

violations=0
checked=0
while IFS= read -r manifest; do
    _dir="$(dirname "$manifest")"
    [[ -f "$_dir/plugin.sh" ]] || continue
    grep -q 'failures+=(' "$_dir/plugin.sh" 2>/dev/null || continue
    checked=$((checked + 1))
    plugin_rel="${manifest#"$_LDC_ROOT"/}"
    state="$(_ldc_classes "$manifest")"
    case "$state" in
        absent)
            echo "✗ $plugin_rel: plugin.sh writes failures[] but the manifest declares no config.valid_failure_classes" >&2
            violations=$((violations + 1))
            ;;
        list*)
            _ldc_list=()
            read -ra _ldc_list <<< "${state#list }"
            for c in "${_ldc_list[@]+"${_ldc_list[@]}"}"; do
                if [[ -z "$(_ag_failure_class_disposition "$c")" ]]; then
                    echo "✗ $plugin_rel: declares failure class '$c', which scripts/lib/acceptance-disposition.sh does not map" >&2
                    echo "    add a row (recoverable | advisory | terminal) or correct the manifest." >&2
                    violations=$((violations + 1))
                fi
            done
            ;;
    esac
done < <(find "$PLUGINS_ROOT" -name manifest.yaml -type f -not -path '*/tests/*' | sort)

if [[ "$checked" -eq 0 ]]; then
    echo "lint-disposition-classify: no failures[] writer found under $PLUGINS_ROOT — a vacuous pass is not a pass" >&2
    exit 1
fi
if [[ "$violations" -gt 0 ]]; then
    echo "lint-disposition-classify: $violations violation(s) across $checked manifest(s)" >&2
    exit 1
fi
echo "lint-disposition-classify: $checked manifest(s) checked, all declared failure classes classify"
