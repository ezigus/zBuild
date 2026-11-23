#!/usr/bin/env bash
# tests/unit/quote-closest-line-test.sh — a quote not found is answered with the
# file's closest line beside it (#2598 R3, ADR-072 §3).
#
# #2532 run 45231040380: red-team's quote held a line break where the file has
# the two characters `\n`; asked again with only "is not in <file>, on one
# line: <quote>", it made the same mistake, and the run stopped.
#
# Q1 [change] the answer shows the file's closest line, as the file has it
# Q2 [change] ...for a near miss of any kind: one wrong word
# Q3 [guard]  a quote that is there needs no answer
# Q4 [guard]  a quote naming a file that is not there says so, as before
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a quote not found shows the closest line (#2598)"
setup_test_env "quote-closest-line"
# shellcheck source=../../scripts/lib/judge-quotes.sh
source "$REPO_ROOT/scripts/lib/judge-quotes.sh"

R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/tests"
cat > "$R/tests/guard.sh" <<'EOF'
#!/usr/bin/env bash
printf '    Linux)  ZBUILD_PLATFORM=linux ;;\n' > "$_zbp_fixture"
printf '    Darwin)  ZBUILD_PLATFORM=macos ;;\n' > "$_zbp_inject"
echo "the host is not the platform"
EOF

print_test_section "Q1: a line break where the file has \\n"
_w=""; judge_quote_check_v _w "tests/guard.sh | printf '    Darwin)  ZBUILD_PLATFORM=macos ;;"$'\n'"' > \"\$_zbp_inject\"" "" "$R" || true
assert_contains "[Q1] the answer shows the closest line, as the file has it" "$_w" "the closest line in it is: printf '    Darwin)  ZBUILD_PLATFORM=macos ;;\\n' > \"\$_zbp_inject\""

print_test_section "Q2: one wrong word"
_w=""; judge_quote_check_v _w 'tests/guard.sh | echo "the host is never the platform"' "" "$R" || true
assert_contains "[Q2] the closest line is shown" "$_w" 'the closest line in it is: echo "the host is not the platform"'

print_test_section "Q3-Q4: guards"
_w="x"; judge_quote_check_v _w 'tests/guard.sh | echo "the host is not the platform"' "" "$R"
assert_eq "[Q3] a quote that is there: rc 0" "0" "$?"
_w=""; judge_quote_check_v _w 'tests/nope.sh | anything' "" "$R" || true
assert_contains "[Q4] a missing file says so" "$_w" "which is not a file of the repository"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
