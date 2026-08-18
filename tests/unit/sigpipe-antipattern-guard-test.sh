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
#
# #1884: the leading `(^|[^|])` is load-bearing — without it the pattern matches
# the SECOND `|` of `||`, and the legitimate `cmd || grep -q ...` reads as a pipe.
_offenders="$(
  {
    grep -rnE '(^|[^|])\|[[:space:]]*([A-Za-z_]+=[^[:space:]|]+[[:space:]]+)*grep[[:space:]]+-[[:alnum:]]*q' \
      "$REPO_ROOT/tests/unit" "$REPO_ROOT/tests/integration" "$REPO_ROOT/tests/e2e" 2>/dev/null || true
    # #1884: ENGINE code too — the hazard is worse there (a SIGPIPE inside a gate
    # makes `if !` take the wrong branch, permissively). legacy/ is frozen, so excluded.
    grep -rnE '(^|[^|])\|[[:space:]]*([A-Za-z_]+=[^[:space:]|]+[[:space:]]+)*grep[[:space:]]+-[[:alnum:]]*q' \
      "$REPO_ROOT/scripts" "$REPO_ROOT/core" "$REPO_ROOT/plugins" \
      --include='*.sh' 2>/dev/null || true
  } | { grep -v '/sigpipe-antipattern-guard-test.sh:' || true; } \
    | { grep -v "^$REPO_ROOT/legacy/" || true; } \
    | { grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true; } \
    | sort -u
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

# ─── #1884: pin the DETECTOR itself, not just the tree ───────────────────────
# The scan above asserts "the tree is clean", which passes just as happily if the
# regex has stopped matching anything. These fixtures pin what it must and must
# not catch. The `||` case is a real regression: the pattern used to match the
# second `|` of `||`, which was invisible while only tests were scanned and
# produced two false positives the moment the scan reached engine code.
_sp_re='(^|[^|])\|[[:space:]]*([A-Za-z_]+=[^[:space:]|]+[[:space:]]+)*grep[[:space:]]+-[[:alnum:]]*q'

_sp_check() { grep -qE "$_sp_re" <<< "$1" && echo yes || echo no; }

print_test_section "[#1884] the detector catches the hazard and nothing else"

assert_eq "[#1884] printf | grep -q            -> offender" \
    "yes" "$(_sp_check 'if printf "%s" "$v" | grep -q foo; then')"
assert_eq "[#1884] echo | grep -q              -> offender" \
    "yes" "$(_sp_check 'if echo "$v" | grep -qF foo; then')"
assert_eq "[#1884] cmd | ENV=x grep -q         -> offender" \
    "yes" "$(_sp_check 'printf "%s" "$v" | LC_ALL=C grep -qF foo')"
assert_eq "[#1884] find | grep -q              -> offender" \
    "yes" "$(_sp_check 'if find . -name x | grep -q .; then')"

assert_eq "[#1884] cmd || grep -q              -> NOT an offender" \
    "no"  "$(_sp_check 'grep -q a f || grep -qF "$b" g')"
assert_eq "[#1884] here-string form            -> NOT an offender" \
    "no"  "$(_sp_check 'if grep -q foo <<< "$v"; then')"
assert_eq "[#1884] grep without -q             -> NOT an offender" \
    "no"  "$(_sp_check 'printf "%s" "$v" | grep -E foo')"

# ─── #1886: `| head` is the same class, and was not covered ──────────────────
# grep -q was one shape. Any reader that exits before its writer finishes has
# the same hazard, and `| head -N` had 45 production instances — one of them in
# the test-result parser, on the path that decides a stage verdict.
#
# Sites where the pipe is genuinely safe carry `# sigpipe-ok: <reason>`, on the
# line itself or within the 8 lines above it (a line ending in `\` cannot take a
# trailing comment, so the marker sits before the statement). Requiring a stated
# reason is the point: a NEW `| head` cannot be added without saying why.
print_test_section "[#1886] every '| head' is converted or justified"

_head_offenders=""
while IFS= read -r _hit; do
    [[ -z "$_hit" ]] && continue
    _hf="${_hit%%:*}"; _rest="${_hit#*:}"; _hl="${_rest%%:*}"
    # marker on the line itself, or on any of the 8 lines above it
    _from=$(( _hl > 8 ? _hl - 8 : 1 ))
    if sed -n "${_from},${_hl}p" "$_hf" 2>/dev/null | grep -q 'sigpipe-ok'; then
        continue
    fi
    _head_offenders+="$_hit"$'\n'
done < <(
    grep -rnE '(^|[^|])\|[[:space:]]*head[[:space:]]+-' \
        "$REPO_ROOT/scripts" "$REPO_ROOT/core" "$REPO_ROOT/plugins" \
        --include='*.sh' 2>/dev/null \
    | { grep -v "^$REPO_ROOT/legacy/" || true; } \
    | { grep -v -- '-test.sh:' || true; } \
    | { grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true; } \
    | sort -u
)

_head_offenders="${_head_offenders%$'\n'}"
if [[ -z "$_head_offenders" ]]; then
    assert_pass "[#1886] no unjustified '| head' in scripts/, core/ or plugins/"
else
    echo "  unjustified '| head' (convert, or add '# sigpipe-ok: <reason>'):" >&2
    head -15 <<< "$_head_offenders" >&2
    assert_fail "[#1886] no unjustified '| head' in scripts/, core/ or plugins/" \
        "found $(grep -cE '.' <<< "$_head_offenders") occurrence(s)"
fi

print_test_results
exit $((FAIL > 0))
