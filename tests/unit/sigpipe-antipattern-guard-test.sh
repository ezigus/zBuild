#!/usr/bin/env bash
# Tests: no pipe into a reader that exits early — `grep -q`, `head` — in any .sh
# file (issues #1015, #1260, #1886, #2639; .zbuild/rules.md).
#
# Under `set -o pipefail`, `grep -q` exits on first match and SIGPIPEs the still-writing
# PRODUCER; the FOUND match becomes a non-zero pipeline → false test failure. It only
# bites under load, so #984 (unit parallel-by-default) surfaced it. #1015 swept the unit
# tier to here-strings (`grep -q PATTERN <<< "$(producer)"`). This guard keeps it swept.
# Auto-discovered by `run-tests.sh --tier unit`, so it gates CI without extra wiring.
#
# The grep -q regex is producer-agnostic (#1022 review): direct, multi-stage, env-prefixed
# and reordered flags (`LC_ALL=C grep -Fq`) — any pipe into `grep -*q*`.
#
# Scope (#2639): every .sh file in the repository (`_sh_files`) — scripts/, core/,
# plugins/ and tests/, test files included, as the rule says — except the frozen
# legacy-DoNotUse/ and installed node_modules/. This guard is scanned too: its pins
# spell the pipe as ${P}, so no line of it holds the pattern as text.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "SIGPIPE antipattern guard — every .sh file (#1015, #1260, #1886, #2639)"

# The pipe character, for pins and fixtures: a pin written with a literal pipe
# would itself be an offender in this file, which the scan reads like any other.
P='|'

# #1884: the leading `(^|[^|])` is load-bearing — without it the pattern matches
# the SECOND `|` of `||`, and the legitimate `cmd || grep -q ...` reads as a pipe.
_sp_re='(^|[^|])\|[[:space:]]*([A-Za-z_]+=[^[:space:]|]+[[:space:]]+)*grep[[:space:]]+-[[:alnum:]]*q'
# #2639: a head by any path (`/usr/bin/head`), through `command` or `env`, after
# `|&`, or with no option — not a regex's alternation, `(a|head|b)`.
_HD_RE='(^|[^|])\|&?[[:space:]]*((command|env)[[:space:]]+)?([^[:space:]|;&()]*/)?head([[:space:]]|$|[;)&])'

# _sh_files <root> — every .sh file under <root>, one per line, but for the
# frozen legacy-DoNotUse/, installed node_modules/ and git's own folder.
_sh_files() {
    find "$1" \( -name .git -o -name node_modules -o -name legacy-DoNotUse \) -prune \
        -o -type f -name '*.sh' -print 2>/dev/null | sort
}

# _sg_scan <regex> <marker|-> <file>... — each line of the files that matches,
# `<file>:<line>:<text>`, except a comment line and, when <marker> is given, a
# line with `# <marker>: <reason>` on it or within the 8 lines above it (a line
# ending in `\` cannot take a trailing comment, so the marker sits before it).
# A marker with no reason excuses nothing: the reason is the point.
_sg_scan() {
    local re="$1" mark="$2" _hit _hf _rest _hl _from
    shift 2
    (( $# )) || return 0
    while IFS= read -r _hit; do
        [[ -z "$_hit" ]] && continue
        _hf="${_hit%%:*}"; _rest="${_hit#*:}"; _hl="${_rest%%:*}"
        if [[ "$mark" != - ]]; then
            _from=$(( _hl > 8 ? _hl - 8 : 1 ))
            grep -qE "# ${mark}:[[:space:]]*[^[:space:]]" <<< "$(sed -n "${_from},${_hl}p" "$_hf" 2>/dev/null)" && continue
        fi
        printf '%s\n' "$_hit"
    done < <(
        grep -HnE "$re" "$@" 2>/dev/null \
        | { grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true; } \
        | sort -u
    )
}

_sg_report() {   # _sg_report <label> <offenders> <how to convert>
    if [[ -z "$2" ]]; then
        assert_pass "$1"
    else
        echo "  offending lines ($3):" >&2
        head -15 <<< "$2" >&2
        assert_fail "$1" "found $(grep -cE '.' <<< "$2") occurrence(s)"
    fi
}

mapfile -t _FILES < <(_sh_files "$REPO_ROOT")

# ─── #1884: pin the DETECTOR itself, not just the tree ───────────────────────
# The tree scan passes just as happily if the regex has stopped matching. The
# `||` case is a real regression: the pattern matched the second `|` of `||`.
_sp_check() { grep -qE "$_sp_re" <<< "$1" && echo yes || echo no; }

print_test_section "[#1884] the grep -q detector catches the hazard and nothing else"
assert_eq "[#1884] printf piped into grep -q      -> offender" "yes" "$(_sp_check "if printf \"%s\" \"\$v\" $P grep -q foo; then")"
assert_eq "[#1884] echo piped into grep -qF       -> offender" "yes" "$(_sp_check "if echo \"\$v\" $P grep -qF foo; then")"
assert_eq "[#1884] piped into ENV=x grep -q       -> offender" "yes" "$(_sp_check "printf \"%s\" \"\$v\" $P LC_ALL=C grep -qF foo")"
assert_eq "[#1884] find piped into grep -q        -> offender" "yes" "$(_sp_check "if find . -name x $P grep -q .; then")"
assert_eq "[#1884] cmd || grep -q                 -> NOT an offender" "no" "$(_sp_check 'grep -q a f || grep -qF "$b" g')"
assert_eq "[#1884] here-string form               -> NOT an offender" "no" "$(_sp_check 'if grep -q foo <<< "$v"; then')"
assert_eq "[#1884] piped into grep without -q     -> NOT an offender" "no" "$(_sp_check "printf \"%s\" \"\$v\" $P grep -E foo")"

_hd_check() { grep -qE "$_HD_RE" <<< "$1" && echo yes || echo no; }

print_test_section "[#2639] the head detector catches a head by any path, and nothing else"
assert_eq "[#2639/SPEC-2] piped into head -1            -> offender" "yes" "$(_hd_check "x=\"\$(grep a f $P head -1)\"")"
assert_eq "[#2639/SPEC-2] piped into /usr/bin/head -1   -> offender" "yes" "$(_hd_check "x=\"\$(grep a f $P /usr/bin/head -1)\"")"
assert_eq "[#2639/SPEC-2] piped into head, no option    -> offender" "yes" "$(_hd_check "printf \"%s\" \"\$v\" $P head")"
assert_eq "[#2639/SPEC-2] piped into head -c 9          -> offender" "yes" "$(_hd_check "x=\$(printf \"%s\" \"\$v\" $P head -c 9)")"
assert_eq "[#2639/SPEC-2] piped with |& into head -1    -> offender" "yes" "$(_hd_check "x=\$(cmd $P& head -1)")"
assert_eq "[#2639/SPEC-2] piped into command head -1    -> offender" "yes" "$(_hd_check "x=\$(cmd $P command head -1)")"
assert_eq "[#2639/SPEC-2] piped into env head -1        -> offender" "yes" "$(_hd_check "x=\$(cmd $P env head -1)")"
assert_eq "[#2639/SPEC-2] cmd || head -1 file           -> NOT an offender" "no" "$(_hd_check 'grep a f || head -1 g')"
assert_eq "[#2639/SPEC-2] head -1 file                  -> NOT an offender" "no" "$(_hd_check 'x=$(head -1 "$f")')"
assert_eq "[#2639/SPEC-2] piped into headers            -> NOT an offender" "no" "$(_hd_check "cmd $P headers -x")"
assert_eq "[#2639/SPEC-2] piped into sed -n 1p          -> NOT an offender" "no" "$(_hd_check "x=\"\$(grep a f $P sed -n 1p)\"")"
assert_eq "[#2639/SPEC-2] a regex's (a|head|b)          -> NOT an offender" "no" "$(_hd_check '[[ "$p" =~ \.(bak|head|tmp)$ ]]')"

# ─── #2639: the files scanned are every .sh file the rule covers ─────────────
# The tree checks below use _sh_files on the repository; this fixture is what
# _sh_files and _sg_scan do with each kind of place and marker.
print_test_section "[#2639] the scan covers every .sh file the rule covers"
_HS="$(mktemp -d "${TMPDIR:-/tmp}/sigpipe-scope.XXXXXX")" || exit 1
mkdir -p "${_HS:?}/plugins/p/tests" "${_HS:?}/tests/lib" "${_HS:?}/legacy-DoNotUse" "${_HS:?}/node_modules/m"
_off="x=\"\$(grep a f $P head -1)\""
printf '%s\n' "$_off" > "${_HS:?}/install.sh"
printf '%s\n' "$_off" > "${_HS:?}/plugins/p/tests/p-test.sh"
printf '%s\n' "y=\"\$(grep a f $P /usr/bin/head -n 2)\"" > "${_HS:?}/tests/lib/h.sh"
printf '%s\n' "$_off" > "${_HS:?}/legacy-DoNotUse/x.sh"
printf '%s\n' "$_off" > "${_HS:?}/node_modules/m/n.sh"
printf '%s\n' '# sigpipe-ok: reads a short list' "$_off" > "${_HS:?}/tests/lib/ok.sh"
printf '%s\n' '# sigpipe-ok' "$_off" > "${_HS:?}/tests/lib/bare.sh"
printf '%s\n' "if echo \"\$v\" $P grep -q x; then :; fi" > "${_HS:?}/tests/lib/q.sh"
mapfile -t _hs_files < <(_sh_files "$_HS")
_hs_out="$(_sg_scan "$_HD_RE" sigpipe-ok "${_hs_files[@]}")"
_hs_q="$(_sg_scan "$_sp_re" - "${_hs_files[@]}")"
_hs_has() { grep -qF -- "$2" <<< "$1" && echo yes || echo no; }
assert_eq "[#2639/SPEC-2] a .sh file at the root is scanned" "yes" "$(_hs_has "$_hs_out" "/install.sh:1:")"
assert_eq "[#2639/SPEC-2] a -test.sh file is scanned" "yes" "$(_hs_has "$_hs_out" "/p-test.sh:1:")"
assert_eq "[#2639/SPEC-2] a file under tests/ is scanned, a head by its path found" "yes" "$(_hs_has "$_hs_out" "/h.sh:1:")"
assert_eq "[#2639/SPEC-2] legacy-DoNotUse/ is not scanned" "no" "$(_hs_has "$_hs_out" "/x.sh:")"
assert_eq "[#2639/SPEC-2] node_modules/ is not scanned" "no" "$(_hs_has "$_hs_out" "/n.sh:")"
assert_eq "[#2639/SPEC-2] a marker with its reason excuses the line" "no" "$(_hs_has "$_hs_out" "/ok.sh:")"
assert_eq "[#2639/SPEC-2] a marker with no reason excuses nothing" "yes" "$(_hs_has "$_hs_out" "/bare.sh:2:")"
assert_eq "[#2639/SPEC-2] the grep -q scan reads the same files" "yes" "$(_hs_has "$_hs_q" "/q.sh:1:")"
rm -rf "${_HS:?}"

# ─── the tree ────────────────────────────────────────────────────────────────
print_test_section "the tree: every .sh file"
_self="$REPO_ROOT/tests/unit/sigpipe-antipattern-guard-test.sh"
assert_eq "[#2639/SPEC-2] this guard is among the files it scans" "yes" "$(_hs_has "$(printf '%s\n' "${_FILES[@]}")" "$_self")"
assert_eq "[#2639/SPEC-2] the root's install.sh is among them" "yes" "$(_hs_has "$(printf '%s\n' "${_FILES[@]}")" "$REPO_ROOT/install.sh")"

# #1886: grep -q was one shape. Any reader that exits before its writer finishes
# has the same hazard, and `| head -N` had 45 production instances — one of them
# in the test-result parser, on the path that decides a stage verdict. #2639
# found 286 more in test files, once the scan reached them. A site where the
# pipe is genuinely safe carries `# sigpipe-ok: <reason>`; a pipe into grep -q
# takes no marker.
_sg_report "[#1015 #1260] no pipe into grep -q in any .sh file" \
    "$(_sg_scan "$_sp_re" - "${_FILES[@]}")" "convert to: grep -q PATTERN <<< \"\$var\""
_sg_report "[#1886] every head reading a pipe is converted or justified, in any .sh file (#2639: tests included)" \
    "$(_sg_scan "$_HD_RE" sigpipe-ok "${_FILES[@]}")" "convert, or add '# sigpipe-ok: <reason>'"

print_test_results
exit $((FAIL > 0))
