#!/usr/bin/env bash
# scripts/lib/lint-verdict-words.sh — #2242
#
# Every verdict word a plugin writes must be one its own manifest declares in
# config.valid_verdicts (#1708). At run time an undeclared word now fails the
# stage (core/pipeline/verdict.sh); this finds it in CI instead. #1838's impact
# plugin wrote `verdict: broken` — a disposition word — on two exits while its
# manifest declared complete|incomplete|error, and every gate passed it.
#
# Reads LITERAL words only — a computed value ($var, $(…)) is checked at run
# time. The shapes recognised, as in lint-disposition-words:
#   - a JSON literal:          "verdict":"<word>"   (also \"-escaped)
#   - a jq object:             verdict:"<word>"
#   - an assignment:           verdict="<word>"
#   - a stage's result writer: *_write_result|*_write_v2 <a> "<word>" …
#     (the verdict is the second argument of every such writer)
# A literal that is not this plugin's own verdict (a lens verdict an aggregator
# reads, say) carries `# verdict-ok: <why>` on the line or in the 3 above.
# A manifest that declares no list is skipped: lint-verdict-classify refuses it.
#
# Usage: bash scripts/lib/lint-verdict-words.sh [plugins_root]
# Exit:  0 = every literal is declared; 1 = at least one is not.
set -euo pipefail

_LVW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LVW_ROOT="$(cd "$_LVW_DIR/../.." && pwd)"
PLUGINS_ROOT="${1:-$_LVW_ROOT/plugins}"

if [[ ! -d "$PLUGINS_ROOT" ]]; then
    echo "lint-verdict-words: plugins root not found: $PLUGINS_ROOT" >&2
    exit 1
fi

# shellcheck source=./manifest-valid-verdicts.sh
source "$_LVW_DIR/manifest-valid-verdicts.sh"

# _lvw_manifest_for <file> — the manifest of the plugin that owns <file>: the
# nearest manifest.yaml walking up, no higher than PLUGINS_ROOT.
_lvw_manifest_for() {
    local d; d="$(dirname "$1")"
    while [[ "$d" == "$PLUGINS_ROOT"* ]]; do
        [[ -f "$d/manifest.yaml" ]] && { printf '%s' "$d/manifest.yaml"; return 0; }
        [[ "$d" == "$PLUGINS_ROOT" ]] && break
        d="$(dirname "$d")"
    done
    return 1
}

_found=0 _bad=0
while IFS= read -r -d '' f; do
    [[ "$f" == */tests/* ]] && continue
    manifest="$(_lvw_manifest_for "$f")" || continue
    # No declared list → nothing to check against here.
    [[ "$(manifest_valid_verdicts_state "$manifest")" == list\ * ]] || continue
    while IFS=$'\t' read -r line word noted; do
        [[ -n "$word" ]] || continue
        _found=$((_found + 1))
        [[ "$noted" == "1" ]] && continue
        if ! manifest_verdict_declared "$manifest" "$word"; then
            echo "lint-verdict-words: ${f#"$PLUGINS_ROOT"/}:$line writes verdict '$word', which ${manifest#"$PLUGINS_ROOT"/} does not declare in valid_verdicts" >&2
            _bad=$((_bad + 1))
        fi
    done < <(awk '
        {
            buf[NR % 4] = $0
            ok = ($0 ~ /# verdict-ok:/)
            for (k = 1; k <= 3 && !ok; k++) if (NR - k > 0 && buf[(NR - k) % 4] ~ /# verdict-ok:/) ok = 1
            s = $0
            # JSON literal, plain or backslash-escaped.
            t = s
            while (match(t, /\\?"verdict\\?"[[:space:]]*:[[:space:]]*\\?"[a-z_]+/)) {
                m = substr(t, RSTART, RLENGTH); sub(/.*"/, "", m)
                print NR "\t" m "\t" ok
                t = substr(t, RSTART + RLENGTH)
            }
            # A jq object key (unquoted): {…,verdict:"w",…}
            t = s
            while (match(t, /[{,[:space:]]verdict[[:space:]]*:[[:space:]]*"[a-z_]+"/)) {
                m = substr(t, RSTART, RLENGTH); sub(/"$/, "", m); sub(/.*"/, "", m)
                print NR "\t" m "\t" ok
                t = substr(t, RSTART + RLENGTH)
            }
            # Assignment to a variable named exactly `verdict`.
            if (match(s, /(^|[^a-zA-Z_])verdict="[a-z_]+"/)) {
                m = substr(s, RSTART, RLENGTH); sub(/.*="/, "", m); sub(/"$/, "", m)
                print NR "\t" m "\t" ok
            }
            # A result writer: the second quoted argument.
            if (match(s, /_write_(result|v2)[[:space:]]+"[^"]*"[[:space:]]+"[a-z_]+"/)) {
                m = substr(s, RSTART, RLENGTH); sub(/"$/, "", m); sub(/.*"/, "", m)
                print NR "\t" m "\t" ok
            }
        }
    ' "$f")
done < <(find "$PLUGINS_ROOT" -name '*.sh' -print0)

if (( _bad > 0 )); then
    echo "lint-verdict-words: $_bad literal verdict(s) not declared by their plugin's manifest (of $_found checked) — declare the word in config.valid_verdicts, use a declared one, or mark a non-own verdict '# verdict-ok: <why>'" >&2
    exit 1
fi
echo "lint-verdict-words: $_found literal verdict(s) checked, all declared by their manifests"
