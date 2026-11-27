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
# still RUNS in the unit tier; it merely SCANS everything. The `| head` check below scans
# every .sh file under scripts/, core/, plugins/ and tests/ (#2639).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

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
    # makes `if !` take the wrong branch, permissively). legacy-DoNotUse/ is frozen, so excluded.
    grep -rnE '(^|[^|])\|[[:space:]]*([A-Za-z_]+=[^[:space:]|]+[[:space:]]+)*grep[[:space:]]+-[[:alnum:]]*q' \
      "$REPO_ROOT/scripts" "$REPO_ROOT/core" "$REPO_ROOT/plugins" \
      --include='*.sh' 2>/dev/null || true
  } | { grep -v '/sigpipe-antipattern-guard-test.sh:' || true; } \
    | { grep -v "^$REPO_ROOT/legacy-DoNotUse/" || true; } \
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
# the test-result parser, on the path that decides a stage verdict. #2639 found
# 286 more in test files, once the scan reached them.
#
# Sites where the pipe is genuinely safe carry `# sigpipe-ok: <reason>`, on the
# line itself or within the 8 lines above it (a line ending in `\` cannot take a
# trailing comment, so the marker sits before the statement). Requiring a stated
# reason is the point: a NEW `| head` cannot be added without saying why.
# #2639: `.zbuild/rules.md` says "in any `.sh` file, test files included", and
# the scan skipped every -test.sh file, looked nowhere under tests/, and missed
# a head called by its path: on #2534 three lenses found `| /usr/bin/head -1`
# in a test file the guard had passed. It now scans every .sh file the rule
# covers, and a head by any path, or with no option.
_HD_RE='(^|[^|])\|&?[[:space:]]*((command|env)[[:space:]]+)?([^[:space:]|;&()]*/)?head([[:space:]]|$|[;)&])'
_hd_check() { grep -qE "$_HD_RE" <<< "$1" && echo yes || echo no; }

print_test_section "[#2639] the head detector catches a head by any path, and nothing else"
assert_eq "[#2639/SPEC-2] cmd | head -1                -> offender" "yes" "$(_hd_check 'x="$(grep a f | head -1)"')"
assert_eq "[#2639/SPEC-2] cmd | /usr/bin/head -1       -> offender" "yes" "$(_hd_check 'x="$(grep a f | /usr/bin/head -1)"')"
assert_eq "[#2639/SPEC-2] cmd | head, no option        -> offender" "yes" "$(_hd_check 'printf "%s" "$v" | head')"
assert_eq "[#2639/SPEC-2] cmd | head -c 9              -> offender" "yes" "$(_hd_check 'x=$(printf "%s" "$v" | head -c 9)')"
assert_eq "[#2639/SPEC-2] cmd |& head -1               -> offender" "yes" "$(_hd_check 'x=$(cmd |& head -1)')"
assert_eq "[#2639/SPEC-2] cmd | command head -1        -> offender" "yes" "$(_hd_check 'x=$(cmd | command head -1)')"
assert_eq "[#2639/SPEC-2] cmd | env head -1            -> offender" "yes" "$(_hd_check 'x=$(cmd | env head -1)')"
assert_eq "[#2639/SPEC-2] cmd || head -1 file          -> NOT an offender" "no" "$(_hd_check 'grep a f || head -1 g')"
assert_eq "[#2639/SPEC-2] head -1 file                 -> NOT an offender" "no" "$(_hd_check 'x=$(head -1 "$f")')"
assert_eq "[#2639/SPEC-2] cmd | headers                -> NOT an offender" "no" "$(_hd_check 'cmd | headers -x')"
assert_eq "[#2639/SPEC-2] cmd | sed -n 1p              -> NOT an offender" "no" "$(_hd_check 'x="$(grep a f | sed -n 1p)"')"
assert_eq "[#2639/SPEC-2] a regex's (a|head|b)         -> NOT an offender" "no" "$(_hd_check '[[ "$p" =~ \.(bak|head|tmp)$ ]]')"

# _head_scan <root>... — each unjustified '| head' under the roots, in any .sh
# file: not a comment line, not this guard (it holds the pattern as text), and
# no `# sigpipe-ok: <reason>` on the line or within the 8 lines above it (a line
# ending in `\` cannot take a trailing comment, so the marker sits before it).
_head_scan() {
    local _hit _hf _rest _hl _from
    while IFS= read -r _hit; do
        [[ -z "$_hit" ]] && continue
        _hf="${_hit%%:*}"; _rest="${_hit#*:}"; _hl="${_rest%%:*}"
        _from=$(( _hl > 8 ? _hl - 8 : 1 ))
        grep -q 'sigpipe-ok' <<< "$(sed -n "${_from},${_hl}p" "$_hf" 2>/dev/null)" && continue
        printf '%s\n' "$_hit"
    done < <(
        grep -rnE "$_HD_RE" "$@" --include='*.sh' 2>/dev/null \
        | { grep -v -e "/legacy-DoNotUse/" -e '/sigpipe-antipattern-guard-test.sh:' || true; } \
        | { grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true; } \
        | sort -u
    )
}

print_test_section "[#2639] the scan covers every .sh file the rule covers"
_HS="$(mktemp -d "${TMPDIR:-/tmp}/sigpipe-scope.XXXXXX")" || exit 1
mkdir -p "${_HS:?}/plugins/p/tests" "${_HS:?}/tests/lib"
printf 'x="$(grep a f | head -1)"\n' > "${_HS:?}/plugins/p/tests/p-test.sh"
printf 'y="$(grep a f | /usr/bin/head -n 2)"\n' > "${_HS:?}/tests/lib/h.sh"
printf '# sigpipe-ok: reads a short list\nz="$(grep a f | head -1)"\n' > "${_HS:?}/tests/lib/ok.sh"
_hs_out="$(_head_scan "${_HS:?}/plugins" "${_HS:?}/tests")"
assert_contains "[#2639/SPEC-2] a -test.sh file is scanned" "$_hs_out" "p-test.sh:1:"
assert_contains "[#2639/SPEC-2] a file under tests/ is scanned, and a head by its path found" "$_hs_out" "h.sh:1:"
_lacks_ok=yes; grep -q 'ok.sh' <<< "$_hs_out" && _lacks_ok=no
assert_eq "[#2639/SPEC-2] a marked line is not an offender" "yes" "$_lacks_ok"
rm -rf "${_HS:?}"

print_test_section "[#1886] every '| head' is converted or justified"
_head_offenders="$(_head_scan "$REPO_ROOT/scripts" "$REPO_ROOT/core" "$REPO_ROOT/plugins" "$REPO_ROOT/tests")"
if [[ -z "$_head_offenders" ]]; then
    assert_pass "[#1886] no unjustified '| head' in any .sh file (#2639: tests included)"
else
    echo "  unjustified '| head' (convert, or add '# sigpipe-ok: <reason>'):" >&2
    head -15 <<< "$_head_offenders" >&2
    assert_fail "[#1886] no unjustified '| head' in any .sh file (#2639: tests included)" \
        "found $(grep -cE '.' <<< "$_head_offenders") occurrence(s)"
fi

print_test_results
exit $((FAIL > 0))
