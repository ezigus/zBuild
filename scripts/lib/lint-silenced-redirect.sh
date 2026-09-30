#!/usr/bin/env bash
# scripts/lib/lint-silenced-redirect.sh — #2246
#
# `cmd < "$f" 2>/dev/null` does NOT silence a missing file: redirections apply
# left to right, so the `<` fails — and bash prints "No such file or directory"
# — before `2>/dev/null` is in place. Write `cmd 2>/dev/null < "$f"` (or group
# it: `{ cmd < "$f"; } 2>/dev/null`). A line that is safe anyway (the file was
# just checked or created) may carry `# redirect-ok: <why>` on it or in the 3
# lines above.
#
# Usage: bash scripts/lib/lint-silenced-redirect.sh [root ...]
#        (default: core scripts plugins under the repo root)
# Exit:  0 = clean; 1 = at least one offending line.
set -euo pipefail

_LSR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $# -eq 0 ]]; then
    set -- "$_LSR_ROOT/core" "$_LSR_ROOT/scripts" "$_LSR_ROOT/plugins"
fi

_bad=0
while IFS= read -r -d '' f; do
    [[ "$f" == */tests/* || "$f" == */legacy/* ]] && continue
    while IFS=$'\t' read -r line text; do
        echo "lint-silenced-redirect: ${f#"$_LSR_ROOT"/}:$line redirects stdin before silencing stderr — a missing file still prints 'No such file'; write 'cmd 2>/dev/null < \"\$f\"': $text" >&2
        _bad=$((_bad + 1))
    done < <(awk '
        {
            buf[NR % 4] = $0
            ok = ($0 ~ /# redirect-ok:/)
            for (k = 1; k <= 3 && !ok; k++) if (NR - k > 0 && buf[(NR - k) % 4] ~ /# redirect-ok:/) ok = 1
            if (ok) next
            s = $0
            sub(/^[[:space:]]*#.*/, "", s)
            # `< "<word>"` (a single `<`, not `<<` / `<<<` / `<(`) and then a
            # 2>/dev/null in the same simple command (no ;, |, &&, || between).
            if (match(s, /(^|[^<])<[[:space:]]*"[^"]+"[^;|&]*2>[[:space:]]*\/dev\/null/)) {
                t = s; gsub(/\t/, " ", t)
                print NR "\t" t
            }
        }
    ' "$f")
done < <(find "$@" -name '*.sh' -print0)

if (( _bad > 0 )); then
    echo "lint-silenced-redirect: $_bad line(s) — put 2>/dev/null before the input redirect" >&2
    exit 1
fi
echo "lint-silenced-redirect: clean"
