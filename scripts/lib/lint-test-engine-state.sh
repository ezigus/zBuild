#!/usr/bin/env bash
# scripts/lib/lint-test-engine-state.sh — #1799: a test makes the engine's loop
# state (`cycle_iterations` in pipeline-state.json) with the engine's own
# writers — zb_engine_loop_state in scripts/lib/test-helpers.sh — never by hand.
#
# A hand-written `cycle_iterations` holds whatever its author assumed. #1799's
# first attempt read an `iterations_used` field the engine never writes (it
# writes `current_iter`), and its test passed because it wrote that field itself.
# Reading the state is fine; writing it is the engine's job.
#
# Refused, in any test .sh under tests/ or plugins/*/*/tests/ (comments aside):
#   a JSON literal  "cycle_iterations":{        a jq key   cycle_iterations: {
#   a jq assignment .cycle_iterations… =  |=  //=
# A line that must hold one (this lint's own test) says `lint-test-engine-state:allow`.
#
# Usage: bash scripts/lib/lint-test-engine-state.sh [root]   (default: the repo)
# Exit:  0 = clean; 1 = at least one offending line.
set -euo pipefail
_LES_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# A jq assignment is told from prose ("…cycle_iterations.status=complete" in an
# assertion label) by what follows the `=`: a value — { [ ( $ or a quote.
_LES_RE='"cycle_iterations"[[:space:]]*:[[:space:]]*\{|(^|[^."A-Za-z_])cycle_iterations[[:space:]]*:[[:space:]]*\{|\.cycle_iterations([.[][^[:space:]=]*)?[[:space:]]*(\|=|//=|=)[[:space:]]*[][{($"]'
_bad=0
while IFS= read -r -d '' f; do
    [[ "$f" == */legacy/* ]] && continue
    _n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        _n=$((_n + 1))
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *"lint-test-engine-state:allow"* ]] && continue
        if [[ "$line" =~ $_LES_RE ]]; then
            echo "lint-test-engine-state: ${f#"$_LES_ROOT"/}:$_n writes cycle_iterations by hand — make it with zb_engine_loop_state (the engine's own writers), so the test holds what the engine really writes" >&2
            _bad=$((_bad + 1))
        fi
    done < "$f"
done < <(find "$_LES_ROOT/tests" "$_LES_ROOT/plugins" -path '*/tests/*' -name '*.sh' -print0 2>/dev/null)
[[ $_bad -eq 0 ]] || exit 1
exit 0
