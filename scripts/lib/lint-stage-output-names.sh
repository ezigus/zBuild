#!/usr/bin/env bash
# scripts/lib/lint-stage-output-names.sh — #2364, ADR-055 §1: no stage's code
# names another stage's output.
#
# Every later stage is handed every earlier stage's output (ADR-068 §8). A stage
# that needs one finds it by what it contains (scripts/lib/earlier-output.sh) —
# never by which stage made it or what that stage calls it. This refuses, in a
# plugin's own code (tests excluded, comments ignored):
#   - a lookup of another plugin's output id in the engine's index
#     (`.inputs.<id>`, `.inputs["<id>"]`, `inputs[<id>]`, `_input <id>`);
#   - another plugin's output file name (a path to its file), unless it is
#     part of a type (`<name>@<n>`).
# A plugin's own outputs are its own business.
#
# Usage: bash scripts/lib/lint-stage-output-names.sh [plugins_root]
set -uo pipefail
_LSO_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_LSO_ROOT="${1:-${ZBUILD_PLUGINS_ROOT:-$_LSO_REPO/plugins}}"

# One row per declared output: "<plugin dir>\t<id>\t<file name>".
_lso_outputs() {
    local m
    for m in "$_LSO_ROOT"/*/*/manifest.yaml; do
        [[ -f "$m" ]] || continue
        awk -v d="${m%/manifest.yaml}" '
            function flush() { if (id != "") print d "\t" id "\t" f; id = ""; f = "" }
            /^outputs:[[:space:]]*$/ { inb = 1; next }
            inb && /^[a-zA-Z_]/ { flush(); inb = 0 }
            inb && /^[[:space:]]*-[[:space:]]+id:/ {
                flush(); l = $0; sub(/^[[:space:]]*-[[:space:]]+id:[[:space:]]*/, "", l)
                sub(/[[:space:]]*#.*/, "", l); gsub(/["\047]/, "", l); id = l; next }
            inb && /^[[:space:]]+path:/ {
                l = $0; sub(/^[[:space:]]+path:[[:space:]]*/, "", l); sub(/[[:space:]]*#.*/, "", l)
                gsub(/["\047]/, "", l); sub(/.*\//, "", l); f = l }
            END { flush() }' "$m"
    done
}

_lso_check() {
    local table="$1" bad=0 dir f
    for dir in "$_LSO_ROOT"/*/*/; do
        dir="${dir%/}"
        [[ -f "$dir/manifest.yaml" ]] || continue
        while IFS= read -r -d '' f; do
            # Every other plugin's ids and file names, as awk patterns.
            awk -F'\t' -v own="$dir" -v file="$f" '
                FNR == NR {
                    if ($1 == own) { mine_id[$2] = 1; if ($3 != "") mine_f[$3] = 1; next }
                    other_id[$2] = $1; if ($3 != "") other_f[$3] = $1; next
                }
                {
                    line = $0
                    if (line ~ /^[[:space:]]*#/) next
                    sub(/[[:space:]]#.*/, "", line)
                    for (i in other_id) {
                        if (i in mine_id) continue
                        if (index(line, ".inputs." i) && match(substr(line, index(line, ".inputs." i) + length(".inputs." i), 1), /^[^A-Za-z0-9_-]?$/) \
                            || index(line, ".inputs[\"" i "\"]") || index(line, "inputs[\"" i "\"]") \
                            || line ~ ("_input[[:space:]]+\"?" i "\"?([^A-Za-z0-9_-]|$)")) {
                            printf "%s:%d: looks up another stage'\''s output by name: %s\n", file, FNR, i; bad = 1
                        }
                    }
                    for (n in other_f) {
                        if (n in mine_f) continue
                        p = index(line, n)
                        if (p && substr(line, p + length(n), 1) != "@" && substr(line, p - 1, 1) !~ /[A-Za-z0-9_-]/) {
                            printf "%s:%d: names another stage'\''s output file: %s\n", file, FNR, n; bad = 1
                        }
                    }
                }
                END { exit bad }' "$table" "$f" || bad=1
        done < <(find "$dir" -name '*.sh' -not -path '*/tests/*' -print0)
    done
    return "$bad"
}

_lso_table="$(mktemp "${TMPDIR:-/tmp}/lint-stage-output-names.XXXXXX")"
trap 'rm -f "$_lso_table"' EXIT
_lso_outputs > "$_lso_table"
if _lso_check "$_lso_table"; then
    printf 'lint-stage-output-names: OK — no stage names another stage'\''s output\n'
    exit 0
fi
printf 'lint-stage-output-names: a stage finds earlier work by what it contains (scripts/lib/earlier-output.sh), never by another stage'\''s output name or file (ADR-055 §1)\n' >&2
exit 1
