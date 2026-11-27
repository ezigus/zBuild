#!/usr/bin/env bash
# scripts/lib/lint-json-text.sh — a JSON string is written or read by the shell
# only in scripts/lib/json-text.sh (zb_json_str_v, zb_json_unescape_v,
# zb_json_strings_v, ZB_JSON_STR_RE). Each copy written elsewhere had its own
# gaps — an escape left out, escapes read in an order that turns a backslash
# before n into a space — so a hand-written one fails here:
#   a \u00XX escape built by printf, a quote escaped for JSON or read back by
#   replacement (${s//\"/\\\"}, ${s//\\\"/\"}), the string-body regex.
# A jq `@tsv` read fails too (#2640): its escapes are never read back, and an
# empty field shifts the ones after it; read NUL-separated instead.
# Scans core/, scripts/ and plugins/ (not a plugin's tests/, not tests/, not
# legacy-DoNotUse/). A comment is not code. A line that must stay — a quote
# escaped for something that is not JSON — is marked
#   # json-text-ok: <reason>
# and the reason is required.
#
# Usage: bash scripts/lib/lint-json-text.sh [repo_root]
# Exit:  0 clean; 1 one or more findings (each printed as file:line: text).
set -euo pipefail

_LJT_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
ROOT="${1:-$(cd "$_LJT_DIR/../.." && pwd)}"
cd "$ROOT"

files=()
while IFS= read -r -d '' f; do files+=("${f#./}"); done < <(
    for d in core scripts plugins; do
        [[ -d "$d" ]] && find "./$d" -name '*.sh' -not -path '*/tests/*' -not -path '*/legacy-DoNotUse/*' \
            -not -path './scripts/lib/json-text.sh' -print0
    done 2>/dev/null || true)
(( ${#files[@]} > 0 )) || exit 0

hits="$( { /usr/bin/grep -HnF -e '//\"/\\\"' -e '//\\\"/\"' -e '(([^"\\]|\\.)*)' "${files[@]}" 2>/dev/null   # json-text-ok: the patterns this lint looks for
           /usr/bin/grep -HnE '\\+u%0?4x' "${files[@]}" 2>/dev/null
           /usr/bin/grep -HnF '@tsv' "${files[@]}" 2>/dev/null; } | sort -u || true)"   # json-text-ok: the pattern this lint looks for
bad=0
while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    f="${h%%:*}"; r="${h#*:}"; l="${r%%:*}"; c="${r#*:}"
    t="${c#"${c%%[![:space:]]*}"}"
    [[ "$t" == \#* ]] && continue
    if [[ "$c" =~ \#[[:space:]]*json-text-ok:(.*)$ ]]; then
        [[ "${BASH_REMATCH[1]}" =~ [^[:space:]] ]] && continue
        printf '%s:%s: a json-text-ok mark needs its reason\n' "$f" "$l"; bad=1; continue
    fi
    if [[ "$c" == *@tsv* ]]; then   # json-text-ok: the pattern this lint looks for
        printf '%s:%s: a tab-separated jq read (@tsv): read it NUL-separated — jq -j with a NUL after each field, then IFS= read -r -d '"''"' each: %s\n' "$f" "$l" "$t"; bad=1; continue   # json-text-ok: its message
    fi
    printf '%s:%s: a JSON string written or read by hand: %s\n' "$f" "$l" "$t"; bad=1
done <<< "$hits"
if (( bad )); then
    printf '%s\n' "lint-json-text: write a JSON string with zb_json_str_v, read one with zb_json_unescape_v or zb_json_strings_v, and find one with ZB_JSON_STR_RE (scripts/lib/json-text.sh); a line that is not JSON may be marked '# json-text-ok: <reason>'" >&2
    exit 1
fi
exit 0
