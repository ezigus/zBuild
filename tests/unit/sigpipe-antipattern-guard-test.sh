#!/usr/bin/env bash
# Tests: no `… | grep -q …` SIGPIPE antipattern across ALL test tiers (issues #1015, #1260).
#
# Under `set -o pipefail`, `grep -q` exits on first match and SIGPIPEs the still-writing
# PRODUCER; the FOUND match becomes a non-zero pipeline → false test failure. It only
# bites under load, so #984 (unit parallel-by-default) surfaced it. #1015 swept the unit
# tier to here-strings (`grep -q PATTERN <<< "$(producer)"`). This guard keeps it swept: it
# fails if ANY pipe-into-grep-q reappears in a test file. Auto-discovered by
# `run-tests.sh --tier unit`, so it gates CI without extra wiring.
#
# The regex is producer-agnostic (#1022 review): it catches direct (`printf "$v" | grep -q`),
# multi-stage (`printf … | head … | grep -q`), env-prefixed / reordered flags
# (`… | LC_ALL=C grep -Fq`), and multi-line `| grep -q` continuations — any `… | grep -*q*`.
#
# Scope = ALL tiers (#1260): unit, integration (`tests/integration/`, `tests/e2e/`) and
# every `*-test.sh` under `plugins/` + `core/`. The SIGPIPE bites integration CI too
# (#1259 review-test.sh:442 "Broken pipe"), so the policy now spans every tier. The guard
# still RUNS in the unit tier; it merely SCANS everything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "SIGPIPE antipattern guard — all tiers (#1015, #1260)"

# `|| true`: grep exits 1 on no-match, which would abort under `set -e` before the assert.
# Self-exclude this guard (it contains the pattern as a regex literal, not a real pipeline).
_offenders="$(
  {
    grep -rnE '\|[[:space:]]*([A-Za-z_]+=[^[:space:]|]+[[:space:]]+)*grep[[:space:]]+-[[:alnum:]]*q' \
      "$REPO_ROOT/tests/unit" "$REPO_ROOT/tests/integration" "$REPO_ROOT/tests/e2e" 2>/dev/null || true
    grep -rnE '\|[[:space:]]*([A-Za-z_]+=[^[:space:]|]+[[:space:]]+)*grep[[:space:]]+-[[:alnum:]]*q' "$REPO_ROOT/plugins" "$REPO_ROOT/core" \
      --include='*-test.sh' 2>/dev/null || true
  } | { grep -v '/sigpipe-antipattern-guard-test.sh:' || true; } \
    | { grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true; }
)"
# (second filter drops full-line COMMENTS that merely mention the pattern — e.g. a
#  doc comment explaining the fix — so they don't read as real offenders.)

if [[ -z "$_offenders" ]]; then
  _count=0
else
  _count="$( { grep -cE '.' <<< "$_offenders" || true; } )"
fi

if [[ "$_count" -eq 0 ]]; then
  assert_pass "no 'printf/echo \"\$var\" | grep -q' SIGPIPE antipattern in any tier"
else
  # Show up to 15 offenders so a regression is actionable.
  echo "  offending lines (printf/echo | grep -q — convert to: grep -q PATTERN <<< \"\$var\"):" >&2
  head -15 <<< "$_offenders" >&2
  assert_fail "all tiers free of the printf|grep -q SIGPIPE antipattern" \
    "found $_count occurrence(s); see list above (#1015, #1260)"
fi

print_test_results
exit $((FAIL > 0))
