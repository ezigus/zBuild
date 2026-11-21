#!/usr/bin/env bash
# tests/unit/test-folder-branch-lines-test.sh — the lines a branch added to, and
# took out of, its test files (zb_test_folder_branch_lines_v, #2520, #2575).
#
# Second review on #2575: a line the branch took out that starts "-- " shows in
# the diff as "--- …", and one it added that starts "++ " as "+++ …"; read as
# file headers, they cost the rest of the file's lines.
#
# L1 [code] a removed "-- …" line is a removed line, and the file's added lines
#           after it are still found
# L2 [code] an added "++ …" line is an added line
# L3 [code] the removed lines are given per file
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/test-paths.sh
source "$REPO_ROOT/scripts/lib/test-paths.sh"
print_test_header "the lines a branch changed in its test files (#2575)"
setup_test_env "test-folder-branch-lines"

R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/tests"
(
    cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t
    printf 'keep\n-- old dashes\nkeep2\n' > tests/a-test.sh
    git add -A && git commit -q -m seed && git checkout -q -b work
    printf 'keep\nkeep2\n++ new pluses\nassert_eq "after" x x\n' > tests/a-test.sh
    git commit -qam change
) >/dev/null 2>&1

declare -A ADDED=() REMOVED=()
zb_test_folder_branch_lines_v ADDED "$R" REMOVED
assert_eq "[L1] the added lines after a removed '-- ' line are found" "3 4" "$(echo ${ADDED[tests/a-test.sh]:-})"
assert_contains "[L2] ...the '++ ' line among them (line 3)" " ${ADDED[tests/a-test.sh]:-} " " 3 "
assert_eq "[L3] the removed line is given for its file" "-- old dashes" "${REMOVED[tests/a-test.sh]%$'\x1e'}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
