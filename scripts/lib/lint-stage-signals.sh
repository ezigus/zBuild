#!/usr/bin/env bash
# scripts/lib/lint-stage-signals.sh — #2225 §2
#
# A plugin records a signal through scripts/lib/stage-signal.sh
# (stage_signal_begin / stage_signal_end), which picks the one word for it —
# `interrupted` — and puts the caller's own handlers back. A raw TERM/INT trap in
# plugins/ is refused; a deliberate one carries `# signal-ok: <why>` on the line
# or within the 3 lines above it (the `# sigpipe-ok` pattern).
#
# Usage: bash scripts/lib/lint-stage-signals.sh [plugins_root]
# Exit:  0 = none found; 1 = at least one raw trap.
set -euo pipefail
_LSS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGINS_ROOT="${1:-$_LSS_ROOT/plugins}"
[[ -d "$PLUGINS_ROOT" ]] || { echo "lint-stage-signals: plugins root not found: $PLUGINS_ROOT" >&2; exit 1; }

_bad=0
while IFS= read -r -d '' f; do
    [[ "$f" == */tests/* ]] && continue
    while IFS=$'\t' read -r line text; do
        echo "lint-stage-signals: ${f#"$PLUGINS_ROOT"/}:$line has a raw TERM/INT trap — use stage_signal_begin/stage_signal_end (scripts/lib/stage-signal.sh), or annotate '# signal-ok: <why>': $text" >&2
        _bad=$((_bad + 1))
    done < <(awk '
        { buf[NR % 4] = $0 }
        /^[[:space:]]*#/ { next }
        /(^|[;&|[:space:]])trap[[:space:]]/ && /(TERM|INT)/ {
            ok = ($0 ~ /# signal-ok:/)
            for (k = 1; k <= 3 && !ok; k++) if (NR - k > 0 && buf[(NR - k) % 4] ~ /# signal-ok:/) ok = 1
            if (!ok) { t = $0; sub(/^[[:space:]]+/, "", t); print NR "\t" t }
        }' "$f")
done < <(find "$PLUGINS_ROOT" -name '*.sh' -print0)

if (( _bad > 0 )); then
    echo "lint-stage-signals: $_bad raw signal trap(s) in plugins/" >&2
    exit 1
fi
echo "lint-stage-signals: no raw TERM/INT traps in plugins/"
