#!/usr/bin/env bash
# Tests: scripts/lib/md-text.sh — the one place the shell writes text into
# GitHub markdown (ADR-065 §5: no process). CommonMark's own rules are the
# reference: any ASCII punctuation character may be backslash-escaped and then
# shows as itself; a fenced block closes only on a run of backticks as long as
# the one that opened it.
#
# M1 [change] zb_md_text_v shows text as written: a backslash before every ASCII
#             punctuation character and nothing else; letters, digits, spaces,
#             newlines and non-ASCII text as they are; an @, a # before a digit
#             and :// broken by a zero-width space (GitHub's mentions, issue
#             links and autolinks are not markdown)
# M2 [change] zb_md_line_v: the same on one line (CR and LF as spaces)
# M3 [change] zb_md_fence_v: a fence one backtick longer than the longest run in
#             the text, three at least
# M4 [change] zb_ansi_strip_v: terminal escapes out, everything else kept
# M5 [change] none of them starts a process
# M6 [change] zb_md_cell_v keeps a table a table: one line, \ and | escaped,
#             the rest as written (a cell read in a terminal stays plain)
# M7 [change] zb_md_inline_v opens no code span: one line, backticks escaped,
#             the rest as written (text for a model or a banner stays plain)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/md-text.sh
source "$REPO_ROOT/scripts/lib/md-text.sh"

print_test_header "md-text — one writer of text into GitHub markdown"
Z=$'\xe2\x80\x8b'

print_test_section "M1: text shown as written"
_P='!"#$%&'"'"'()*+,-./:;<=>?@[\]^_`{|}~'
_got=""; zb_md_text_v _got "$_P"
_want=""; for (( _i = 0; _i < ${#_P}; _i++ )); do _want+="\\${_P:_i:1}"; done
_want="${_want//@/@$Z}"
assert_eq "[M1] every ASCII punctuation character is escaped, each once" "$_want" "$_got"
_got=""; zb_md_text_v _got $'plain Text 42\nline two café 日本'
assert_eq "[M1] letters, digits, spaces, newlines and non-ASCII text are as they are" $'plain Text 42\nline two café 日本' "$_got"
_got=""; zb_md_text_v _got 'ask @octocat'
assert_eq "[M1] an @ mentions no one" "ask \\@${Z}octocat" "$_got"
_got=""; zb_md_text_v _got 'see 2534'
assert_eq "[M1] a number alone stays" "see 2534" "$_got"
_got=""; zb_md_text_v _got 'see #2534'
assert_eq "[M1] a # before a digit links no issue" "see \\#${Z}2534" "$_got"
_got=""; zb_md_text_v _got 'go https://x.example'
assert_eq "[M1] :// makes no link" "go https\\:${Z}\\/\\/x\\.example" "$_got"

print_test_section "M2: one line"
_got=""; zb_md_line_v _got $'a *b*\r\nc|d'
assert_eq "[M2] CR and LF are spaces, and the rest as M1" 'a \*b\*  c\|d' "$_got"

print_test_section "M3: a fence the text cannot close"
_got=""; zb_md_fence_v _got 'no backticks'; assert_eq "[M3] three at least" '```' "$_got"
_got=""; zb_md_fence_v _got 'a `span` here'; assert_eq "[M3] ...a short run needs no more" '```' "$_got"
_got=""; zb_md_fence_v _got $'```\ncode\n```'; assert_eq "[M3] three in the text: four" '````' "$_got"
_got=""; zb_md_fence_v _got $'````\nx\n````'; assert_eq "[M3] four in the text: five" '`````' "$_got"
_got=""; zb_md_fence_v _got $'``` and ``````'; assert_eq "[M3] the longest run counts" '```````' "$_got"
_got=""; zb_md_fence_v _got $'`````` and ```'; assert_eq "[M3] ...wherever it is" '```````' "$_got"

print_test_section "M4: terminal escapes out"
_got=""; zb_ansi_strip_v _got $'\e[31mred\e[0m and \e[?25lhidden\e[1;2H at\eM end'
assert_eq "[M4] colour, cursor and single-character escapes are gone" "red and hidden at end" "$_got"
_got=""; zb_ansi_strip_v _got 'no [31m escape'
assert_eq "[M4] text that only looks like one stays" "no [31m escape" "$_got"

print_test_section "M6: a table cell"
_got=""; zb_md_cell_v _got $'ADR-012: a|b \\ *c*\nnext'
assert_eq "[M6] one line, the pipe and backslash escaped, the rest as written" 'ADR-012: a\|b \\ *c* next' "$_got"

print_test_section "M7: inline text"
_got=""; zb_md_inline_v _got $'run `x` _now_\r\nok'
assert_eq "[M7] one line, backticks escaped, the rest as written" 'run \`x\` _now_  ok' "$_got"

# Bash review on the markdown PR: the strip is one pass in the shell up to its
# limit, and one sed past it (the digest's precedent) — never one pass per escape.
_short=""; for (( _i = 0; _i < 25; _i++ )); do _short+=$'\e[1mx\e[0m'; done
assert_eq "[M4] (fixture) many escapes in a string under the shell's limit" "1" "$(( ${#_short} <= _ZB_ANSI_SHELL_MAX ))"
_got=""; zb_ansi_strip_v _got "$_short"
assert_eq "[M4] many escapes in a short string: all out" "$(printf 'x%.0s' {1..25})" "$_got"
_big=""; while (( ${#_big} <= _ZB_ANSI_SHELL_MAX )); do _big+=$'\e[31mx\e[0m\eMy\e[200~'; done
_got=""; zb_ansi_strip_v _got "$_big"$'\e[1m!\n\n'
assert_eq "[M4] a string past the shell's limit: every kind of escape out" "$(( ${#_big} / 19 * 2 + 3 ))" "${#_got}"
assert_eq "[M4] ...nothing but the text left" "" "${_got//[xy!$'\n']/}"
assert_eq "[M4] ...its own trailing newlines kept" $'!\n\n' "${_got: -3}"
_got=""; zb_ansi_strip_v _got $'a\e[200~b\e[201~c'
assert_eq "[M4] a short string's escapes that end in ~ (pasted-text markers) are out" "abc" "$_got"
_got=""; zb_ansi_strip_v _got $'\e[\e[1m31m'
assert_eq "[M4] an escape inside an unfinished one: read as sed reads it" "31m" "$_got"

print_test_section "M5: no process"
# shellcheck disable=SC2123  # PATH emptied on purpose: no command can run
_np="$(PATH=/nonexistent; _a=""; zb_md_text_v _a '*x* @y'; _b=""; zb_md_line_v _b $'1\n2'
       _c=""; zb_md_fence_v _c '````'; _d=""; zb_ansi_strip_v _d $'\e[1mB\e[0m'; printf '%s|%s|%s|%s' "$_a" "$_b" "$_c" "$_d")"
assert_eq "[M5] with no command on PATH, each still works" "\\*x\\* \\@${Z}y|1 2|\`\`\`\`\`|B" "$_np"

print_test_results
exit $((FAIL > 0))
