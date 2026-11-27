#!/usr/bin/env bash
# Tests: scripts/lib/json-text.sh — the one place a JSON string is written or
# read by the shell (ADR-065 §5: no process).
#
# J1 [change] zb_json_str_v writes a string as jq writes it: jq is the
#             reference for every sample (quote, backslash, a backslash before
#             n, tab, newline, CR, \b \f, other control bytes, DEL, non-ASCII
#             text, a slash, an empty string)
# J2 [change] zb_json_unescape_v reads a string's body back: each sample,
#             written by jq or by J1, reads back as it was; every JSON escape
#             (\/ \b \f \n \r \t \" \\ \uXXXX, a surrogate pair) is read
# J3 [change] zb_json_strings_v reads each string of a JSON array, whole: a
#             comma, a space, an escaped quote or backslash stays in its own
#             string
# J4 [change] none of them starts a process
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/json-text.sh
source "$REPO_ROOT/scripts/lib/json-text.sh"

print_test_header "json-text — one JSON string writer and reader for the shell"

_S=(
    'plain text'
    'a "quoted" \ word'
    'x\ny — a backslash before n, not a newline'
    $'a\tb\nc\rd'
    $'bell\x07 back\b feed\f'
    $'low \x01\x02\x1f and DEL \x7f'
    $'only DEL \x7f'
    'café — 日本 😀'
    'two b/w.sh'
    ''
)
_N=("plain" "quote and backslash" "backslash before n" "tab, newline, CR" "\\b \\f and a bell"
    "control bytes and DEL" "DEL on its own" "non-ASCII" "a slash" "empty")

print_test_section "J1: a string is written as jq writes it"
for _i in "${!_S[@]}"; do
    _want="$(printf '%s' "${_S[_i]}" | jq -Rs .)"
    _got=""; zb_json_str_v _got "${_S[_i]}"
    assert_eq "[J1] ${_N[_i]}" "$_want" "$_got"
done

print_test_section "J2: a string's body reads back as it was"
for _i in "${!_S[@]}"; do
    _j="$(printf '%s' "${_S[_i]}" | jq -Rs .)"; _j="${_j#\"}"; _j="${_j%\"}"
    _got=""; zb_json_unescape_v _got "$_j"
    assert_eq "[J2] ${_N[_i]}, as jq wrote it" "${_S[_i]}" "$_got"
    _e=""; zb_json_str_v _e "${_S[_i]}"; _e="${_e#\"}"; _e="${_e%\"}"
    _got=""; zb_json_unescape_v _got "$_e"
    assert_eq "[J2] ${_N[_i]}, as J1 wrote it" "${_S[_i]}" "$_got"
done
_got=""; zb_json_unescape_v _got 'a\/b'; assert_eq "[J2] \\/ is a slash" "a/b" "$_got"
_got=""; zb_json_unescape_v _got '\u0041\u00e9\u65e5'; assert_eq "[J2] \\uXXXX is its character" "Aé日" "$_got"
_got=""; zb_json_unescape_v _got '\ud83d\ude00'; assert_eq "[J2] a surrogate pair is one character" "😀" "$_got"
_got=""; zb_json_unescape_v _got '\\n'; assert_eq "[J2] an escaped backslash before n stays a backslash and an n" '\n' "$_got"
_got=""; zb_json_unescape_v _got '\\\"'; assert_eq "[J2] an escaped backslash before an escaped quote" '\"' "$_got"

print_test_section "J3: each string of an array, whole"
_arr=()
zb_json_strings_v _arr '["a","b \"q\"","c\\d","x,y", "two b/w.sh"]'
assert_eq "[J3] five strings" "5" "${#_arr[@]}"
assert_eq "[J3] a plain one" "a" "${_arr[0]:-}"
assert_eq "[J3] an escaped quote stays in its string" 'b "q"' "${_arr[1]:-}"
assert_eq "[J3] an escaped backslash" 'c\d' "${_arr[2]:-}"
assert_eq "[J3] a comma" "x,y" "${_arr[3]:-}"
assert_eq "[J3] a space and \" b/\"" "two b/w.sh" "${_arr[4]:-}"
_arr=(); zb_json_strings_v _arr '[]'; assert_eq "[J3] an empty array is no strings" "0" "${#_arr[@]}"

print_test_section "J4: no process"
# shellcheck disable=SC2123  # PATH emptied on purpose: no command can run
_np="$(PATH=/nonexistent; _a=""; zb_json_str_v _a $'q"\t\x01é'; _b=""; zb_json_unescape_v _b '\u00e9\ud83d\ude00\t'
       _c=(); zb_json_strings_v _c '["a","b"]'; printf '%s|%s|%s' "$_a" "$_b" "${#_c[@]}")"
assert_eq "[J4] with no command on PATH, each still works" "\"q\\\"\\t\\u0001é\"|é😀"$'\t'"|2" "$_np"

print_test_results
exit $((FAIL > 0))
