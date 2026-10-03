#!/usr/bin/env bash
# scripts/lib/lint-adr-enforced-by.sh — #2268
#
# Every ADR statement has a test. A rule that lives only in an ADR's prose is a
# missing test: #1844 run 37066147994 passed every gate with a stage the engine
# never read as v2, because ADR-054 §5 ("the result file is the primary output")
# had nothing enforcing it.
#
# This lint makes the rule mechanical. A live ADR (not Superseded / Deprecated /
# Withdrawn / Rejected) carries an `## Enforced by` section naming the tests that
# enforce its statements, and every test or lint path named there must exist.
#
# The ADRs written before this rule are listed in config/adr-enforcement-baseline.txt.
# The baseline only shrinks: an entry whose ADR now has its section, or whose ADR
# is gone, is itself a failure — remove the entry. A new ADR is never added to it.
#
# Usage: bash scripts/lib/lint-adr-enforced-by.sh [repo_root]
# Exit:  0 = every live ADR is enforced or baselined; 1 = violation.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ADR_DIR="$ROOT/docs/adr"
BASELINE="$ROOT/config/adr-enforcement-baseline.txt"
[[ -d "$ADR_DIR" ]] || { echo "lint-adr-enforced-by: no $ADR_DIR" >&2; exit 1; }

declare -A _baselined=()
if [[ -f "$BASELINE" ]]; then
    while IFS= read -r _l || [[ -n "$_l" ]]; do
        _l="${_l%%#*}"; _l="${_l//[[:space:]]/}"
        [[ -n "$_l" ]] && _baselined["$_l"]=1
    done < "$BASELINE"
fi

bad=0 checked=0
for f in "$ADR_DIR"/ADR-*.md; do
    [[ -f "$f" ]] || continue
    name="${f##*/}"
    status_line=""
    while IFS= read -r line; do
        if [[ "$line" == '**Status:**'* ]]; then status_line="$line"; break; fi
    done < "$f"
    shopt -s nocasematch
    if [[ "$status_line" =~ superseded|deprecated|withdrawn|rejected ]]; then
        shopt -u nocasematch
        [[ -n "${_baselined[$name]:-}" ]] && {
            echo "lint-adr-enforced-by: $name is $status_line — it needs no entry in the baseline; remove it" >&2; bad=$((bad + 1)); }
        unset "_baselined[$name]"
        continue
    fi
    shopt -u nocasematch
    checked=$((checked + 1))
    # The section runs from its heading to the next level-2 heading.
    section=""; in_sec=0
    while IFS= read -r line; do
        if [[ "$line" == '## '* ]]; then
            [[ "$line" == '## Enforced by'* ]] && { in_sec=1; continue; }
            [[ $in_sec -eq 1 ]] && break
        fi
        [[ $in_sec -eq 1 ]] && section+="$line"$'\n'
    done < "$f"
    if [[ $in_sec -eq 0 ]]; then
        if [[ -z "${_baselined[$name]:-}" ]]; then
            echo "lint-adr-enforced-by: $name has no '## Enforced by' section naming the tests that enforce its statements" >&2
            bad=$((bad + 1))
        fi
        unset "_baselined[$name]"
        continue
    fi
    if [[ -n "${_baselined[$name]:-}" ]]; then
        echo "lint-adr-enforced-by: $name now has its '## Enforced by' section — remove it from config/adr-enforcement-baseline.txt" >&2
        bad=$((bad + 1))
        unset "_baselined[$name]"
    fi
    # Every backticked repo path in the section must exist.
    rest="$section"; named=0
    while [[ "$rest" =~ \`((tests|scripts|core|plugins)/[^\`[:space:]]+)\` ]]; do
        p="${BASH_REMATCH[1]}"; rest="${rest#*"\`$p\`"}"
        named=$((named + 1))
        p="${p%%:*}"   # allow file:line
        [[ -e "$ROOT/$p" ]] || { echo "lint-adr-enforced-by: $name names $p, which does not exist" >&2; bad=$((bad + 1)); }
    done
    if [[ $named -eq 0 ]]; then
        echo "lint-adr-enforced-by: $name has an '## Enforced by' section that names no test" >&2
        bad=$((bad + 1))
    fi
done

for stale in "${!_baselined[@]}"; do
    echo "lint-adr-enforced-by: the baseline lists $stale, which is not in docs/adr — remove the entry" >&2
    bad=$((bad + 1))
done

if [[ $bad -gt 0 ]]; then
    echo "lint-adr-enforced-by: $bad problem(s) among $checked live ADR(s)" >&2
    exit 1
fi
echo "lint-adr-enforced-by: $checked live ADR(s) checked, every one enforced or baselined"
