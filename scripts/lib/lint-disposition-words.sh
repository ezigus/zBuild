#!/usr/bin/env bash
# scripts/lib/lint-disposition-words.sh — #2187 (ADR-054 §6a)
#
# Every disposition word a stage writes must be a member of the engine's closed
# set (core/pipeline/disposition.sh). At run time an off-set word is refused as a
# structural failure; this finds it in CI instead. #1849's run was full of words
# whose meaning had drifted from what the engine does with them.
#
# Reads LITERAL words only — a computed value ($var, $(…)) is the engine's own
# mapping and is checked where that mapping lives. Two shapes are recognised:
#   - a JSON literal:            "disposition":"<word>"   (also \"-escaped)
#   - an assignment:             disposition=/_disp=/…_disposition="<word>"
#   - a stage's result writer:   *_write_result|*_write_v2 <a> <b> "<word>" …
#     (the disposition is the third argument of every such writer)
# A writer call split across lines is not seen; that is the known blind spot.
#
# Usage: bash scripts/lib/lint-disposition-words.sh [plugins_root]
# Exit:  0 = every literal word is in the set; 1 = at least one is not.
set -euo pipefail

_LDW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LDW_ROOT="$(cd "$_LDW_DIR/../.." && pwd)"
PLUGINS_ROOT="${1:-$_LDW_ROOT/plugins}"

if [[ ! -d "$PLUGINS_ROOT" ]]; then
    echo "lint-disposition-words: plugins root not found: $PLUGINS_ROOT" >&2
    exit 1
fi

# shellcheck source=../../core/pipeline/disposition.sh
source "$_LDW_ROOT/core/pipeline/disposition.sh"

_found=0 _bad=0
while IFS= read -r -d '' f; do
    [[ "$f" == */tests/* ]] && continue
    while IFS=$'\t' read -r line word noted; do
        [[ -n "$word" ]] || continue
        _found=$((_found + 1))
        # #2225: `unavailable` ends the run as "an external service zBuild depends
        # on is not responding" — resumable once it is back. A stage that uses it
        # names the service: `# disposition-ok: <service> …` on the line or in
        # the 3 above. #1837's intake wrote it for a CLOSED issue, which no
        # outage explains and no resume fixes.
        if [[ "$word" == "unavailable" && "$noted" != "1" ]]; then
            echo "lint-disposition-words: ${f#"$PLUGINS_ROOT"/}:$line writes 'unavailable' without naming the external service — add '# disposition-ok: <service> is not responding' (or derive it from router_reason_disposition)" >&2
            _bad=$((_bad + 1))
        fi
        if ! disposition_is_valid "$word"; then
            echo "lint-disposition-words: ${f#"$PLUGINS_ROOT"/}:$line writes disposition '$word', which the engine does not know" >&2
            _bad=$((_bad + 1))
        fi
    done < <(awk '
        {
            buf[NR % 4] = $0
            ok = ($0 ~ /# disposition-ok:/)
            for (k = 1; k <= 3 && !ok; k++) if (NR - k > 0 && buf[(NR - k) % 4] ~ /# disposition-ok:/) ok = 1
            s = $0
            # JSON literal, plain or backslash-escaped.
            t = s
            while (match(t, /\\?"disposition\\?"[[:space:]]*:[[:space:]]*\\?"[a-z_]+/)) {
                m = substr(t, RSTART, RLENGTH); sub(/.*"/, "", m)
                print NR "\t" m "\t" ok
                t = substr(t, RSTART + RLENGTH)
            }
            # Assignment to a disposition variable.
            if (match(s, /(^|[^a-zA-Z_])(disposition|_disp|_disposition|[a-z_]+_disposition)="[a-z_]+"/)) {
                m = substr(s, RSTART, RLENGTH); sub(/.*="/, "", m); sub(/"$/, "", m)
                print NR "\t" m "\t" ok
            }
            # A result writer: the third quoted argument.
            if (match(s, /_write_(result|v2)[[:space:]]+"[^"]*"[[:space:]]+"[^"]*"[[:space:]]+"[a-z_]+"/)) {
                m = substr(s, RSTART, RLENGTH); sub(/"$/, "", m); sub(/.*"/, "", m)
                print NR "\t" m "\t" ok
            }
        }
    ' "$f")
done < <(find "$PLUGINS_ROOT" -name '*.sh' -print0)

if (( _bad > 0 )); then
    echo "lint-disposition-words: $_bad problem(s) among $_found literal disposition(s) — an off-set word, or an unexplained 'unavailable'; the set is: $(disposition_vocabulary)" >&2
    exit 1
fi
echo "lint-disposition-words: $_found literal disposition(s) checked, all in the engine's set"
