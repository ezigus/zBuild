#!/usr/bin/env bash
# tests/unit/shell-join-test.sh — a shell file read as whole commands, its line
# numbers kept (#2460).
#
# Why: the repository's lints check shell code one line at a time, so a command
# continued onto the next line (`\`, or a line ending in `|`, `&&` or `||`)
# slipped past them, or tripped them falsely. zb_shell_join gives each lint the
# whole command on its first line, the lines it took left blank, so every line
# number a lint reports is still right.
#
# S1 [change] a command continued with a backslash is joined onto its first line
# S2 [change] ...and one continued by a trailing |, && or ||
# S3 [change] the file keeps its line count; the lines taken are blank
# S4 [guard]  a backslash in a comment, a quoted string or a heredoc body joins
#             nothing
# S5 [change] zb_shell_code_named gives each command as code: quoted text and
#             comments blanked, heredoc bodies left out, the line kept
# S6 [change] a $'...' string is quoted text too, a \' inside it included
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/shell-join.sh
source "$REPO_ROOT/scripts/lib/shell-join.sh" 2>/dev/null || true
print_test_header "a shell file read as whole commands (#2460)"
setup_test_env "shell-join"

F="$TEST_TEMP_DIR/x.sh"
printf '%s\n' \
    'route_to_model "$tier" \' \
    '    "$prompt" 2>/dev/null' \
    "printf '%s' \"\$x\" |" \
    '    atomic_write "$f" || true' \
    "echo 'a \\'" \
    '# a comment \' \
    'real_cmd' \
    'cat <<HD' \
    'body line \' \
    'HD' \
    'last' \
    "cat <<'QH'" \
    'quoted body \' \
    'next body line' \
    'QH' > "$F"
_out="$(zb_shell_join "$F" 2>/dev/null)"
assert_eq "[S1] a backslash-continued command is joined on its first line" 'route_to_model "$tier" "$prompt" 2>/dev/null' \
    "$(sed -n 1p <<< "$_out" | tr -s ' ')"
assert_eq "[S2] ...and a pipe-continued one" "printf '%s' \"\$x\" | atomic_write \"\$f\" || true" "$(sed -n 3p <<< "$_out" | tr -s ' ')"
assert_eq "[S3] the file keeps its line count" "15" "$(printf '%s\n' "$_out" | wc -l | tr -d ' ')"
assert_eq "[S3] ...the line taken is blank" "" "$(sed -n 2p <<< "$_out")"
assert_eq "[S4] a backslash inside quotes joins nothing" "echo 'a \\'" "$(sed -n 5p <<< "$_out")"
assert_eq "[S4] ...nor one in a comment" "real_cmd" "$(sed -n 7p <<< "$_out")"
assert_eq "[S4] ...nor one in a heredoc body" "HD" "$(sed -n 10p <<< "$_out")"
assert_eq "[S4] ...nor one in a quoted heredoc's body (review on #2461)" "quoted body \\" "$(sed -n 13p <<< "$_out")"
assert_eq "[S4] ...whose next line stays its own" "next body line" "$(sed -n 14p <<< "$_out")"

_code="$(zb_shell_code_named "$F" 2>/dev/null)"
assert_contains "[S5] a command is named by its file and first line" "$_code" "$F:1:route_to_model "
assert_eq "[S5] ...its quoted text blanked" "route_to_model 2>/dev/null" \
    "$(sed -n 1p <<< "$_code" | cut -d: -f3- | tr -s ' ' | sed 's/^ //')"
assert_eq "[S5] a comment is left out" "" "$(/usr/bin/grep -F 'a comment' <<< "$_code" || true)"
assert_eq "[S5] a heredoc body is left out" "" "$(/usr/bin/grep -E 'body line|quoted body' <<< "$_code" || true)"
assert_contains "[S5] ...the command after it is kept, at its own line" "$_code" "$F:11:last"

F6="$TEST_TEMP_DIR/ansi.sh"
printf '%s\n' "x=\$'a \\' b; run_me c' && after" 'next_cmd' > "$F6"
_c6="$(zb_shell_code_named "$F6" 2>/dev/null)"
assert_eq "[S6] a \$'...' string, \\' and all, is blanked" "x= && after" \
    "$(sed -n 1p <<< "$_c6" | cut -d: -f3- | tr -s ' ')"
assert_contains "[S6] ...and the next line is code" "$_c6" "$F6:2:next_cmd"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
