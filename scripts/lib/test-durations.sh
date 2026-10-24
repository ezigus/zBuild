#!/usr/bin/env bash
# scripts/lib/test-durations.sh <timing-log> [out] — write tests/test-durations.tsv
# from a ZBUILD_TEST_TIMING_FILE log (ADR-065).
#
# scripts/run-tests.sh starts a tier's pool longest-first by this file, so a
# long file never starts last and holds the tier open. Lines are
# `<whole seconds>TAB<path relative to the repo root>`, longest first; a file
# timed twice keeps its slowest record; a file outside the repo is dropped.
#
#   ZBUILD_TEST_TIMING_FILE=/tmp/t.log npm test && bash scripts/lib/test-durations.sh /tmp/t.log
set -euo pipefail

_TD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log="${1:?usage: test-durations.sh <timing-log> [out]}"
out="${2:-$_TD_ROOT/tests/test-durations.tsv}"

awk -v root="$_TD_ROOT/" '
    $1 == "file" && index($3, root) == 1 {
        p = substr($3, length(root) + 1)
        if (!(p in ms) || $2 + 0 > ms[p]) ms[p] = $2 + 0
    }
    END { for (p in ms) printf "%d\t%s\n", int(ms[p] / 1000), p }
' "$log" | sort -t $'\t' -k1,1nr -k2,2 > "$out"
