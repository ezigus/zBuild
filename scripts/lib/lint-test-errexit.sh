#!/usr/bin/env bash
# scripts/lib/lint-test-errexit.sh — #2252 G
#
# A test file that runs without stop-on-error (its first `set -…` line has no
# `e`) must not turn it on later: from that line every assertion that expects a
# non-zero rc kills the file instead of being checked. #1844's test-author
# wrapped a call in `set +e … set -e` inside a `set -uo pipefail` file and the
# next expected rc=1 aborted it. A file that starts with -e may toggle it.
#
# Usage: bash scripts/lib/lint-test-errexit.sh [root]   (default: the repo)
# Exit:  0 = clean; 1 = at least one offending file.
set -euo pipefail

_LTE_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
_bad=0
while IFS= read -r -d '' f; do
    [[ "$f" == */legacy-DoNotUse/* ]] && continue
    # One awk pass: the header is the first `set -<flags>` line of the file's own
    # shell; heredoc bodies are skipped — a fixture script written by the test is
    # not the test's own shell (its `set -e` is the fixture's business).
    while IFS=$'\t' read -r ln header; do
        [[ -n "$ln" ]] || continue
        echo "lint-test-errexit: ${f#"$_LTE_ROOT"/}:$ln turns stop-on-error on in a file that runs without it (header: ${header:-none}) — an expected non-zero rc after this line kills the file; use 'cmd || rc=\$?' instead" >&2
        _bad=$((_bad + 1))
    done < <(awk '
        doc != "" { t = $0; sub(/^\t+/, "", t); if (t == doc) doc = ""; next }
        /^[[:space:]]*#/ { next }
        # The line itself is judged BEFORE a heredoc it opens hides what follows:
        # a set -e on the opening line belongs to the test shell (review #2253).
        !seen && /^set -[a-zA-Z]+/ {
            seen = 1; hdr = $0; f = $2; sub(/^-/, "", f)
            haserr = (f ~ /e/); next
        }
        seen && !haserr && /^[[:space:]]*set -[a-zA-Z]*e[a-zA-Z]*([[:space:]]|$)/ { print NR "\t" hdr }
        {
            line = $0
            if (match(line, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
                d = substr(line, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*/, "", d); gsub(/["\047]/, "", d)
                if (line !~ /<<</) doc = d
            }
        }
    ' "$f" 2>/dev/null)
done < <(find "$_LTE_ROOT/tests" "$_LTE_ROOT/plugins" -name '*-test.sh' -print0 2>/dev/null)

if (( _bad > 0 )); then
    echo "lint-test-errexit: $_bad file(s) switch stop-on-error on mid-file" >&2
    exit 1
fi
echo "lint-test-errexit: clean"
