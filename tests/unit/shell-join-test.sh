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
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
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
    'last' > "$F"
_out="$(zb_shell_join "$F" 2>/dev/null)"
assert_eq "[S1] a backslash-continued command is joined on its first line" 'route_to_model "$tier" "$prompt" 2>/dev/null' \
    "$(sed -n 1p <<< "$_out" | tr -s ' ')"
assert_eq "[S2] ...and a pipe-continued one" "printf '%s' \"\$x\" | atomic_write \"\$f\" || true" "$(sed -n 3p <<< "$_out" | tr -s ' ')"
assert_eq "[S3] the file keeps its line count" "11" "$(printf '%s\n' "$_out" | wc -l | tr -d ' ')"
assert_eq "[S3] ...the line taken is blank" "" "$(sed -n 2p <<< "$_out")"
assert_eq "[S4] a backslash inside quotes joins nothing" "echo 'a \\'" "$(sed -n 5p <<< "$_out")"
assert_eq "[S4] ...nor one in a comment" "real_cmd" "$(sed -n 7p <<< "$_out")"
assert_eq "[S4] ...nor one in a heredoc body" "HD" "$(sed -n 10p <<< "$_out")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
