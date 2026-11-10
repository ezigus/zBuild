#!/usr/bin/env bash
# tests/unit/acceptance-testfile-sections-test.sh — the test file shown to
# test-author's check keeps its Given/When/Then headings and no other comment
# (#2474, ADR-073 §6).
#
# Why: the check is asked whether each test is laid out in sections marked by
# comments, but it was shown the file with every comment removed. On #1805 run
# 42090130741 try 2 added the headings, and the check still said they were
# missing: it could never see them.
#
# S1 [code]  a heading comment is shown: Given, When, Then, And, Cleanup, in any
#            case, indented, with or without a colon or formatting
# S2 [guard] any other comment is not shown: a note, a trailing comment, a word
#            that only starts like a heading (Thereafter)
# S3 [guard] a file with no headings shows no comment
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "the check is shown a test's section headings (#2474)"
setup_test_env "acceptance-testfile-sections"
# shellcheck source=../../scripts/lib/acceptance-coverage.sh
source "$REPO_ROOT/scripts/lib/acceptance-coverage.sh"

R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/tests"
# Given a test laid out in sections, with other comments too
cat > "$R/tests/a-test.sh" <<'SH'
#!/usr/bin/env bash
# A note about this file
# Given a run interrupted in stage 3
run_to 3
  # When: it is resumed
  resume # resumes it
# **Then** stages 1 and 2 are not dispatched
assert_eq "[#1805/RHYD-1] not dispatched" "0" "$n"
#and the outputs are byte-identical
assert_eq "[#1805/RHYD-1] same bytes" "$a" "$b"
# THEN stage 3 runs
# Thereafter nothing else matters
# Cleanup
rm -rf "$d"
SH
# When the check's view of it is made
OUT="$(acceptance_testfile_source "$R" tests/a-test.sh '[#1805/RHYD-1]')"
# Then the headings are there, as written, and nothing else that is a comment
for _h in '# Given a run interrupted in stage 3' '# When: it is resumed' '# **Then** stages 1 and 2 are not dispatched' \
          '#and the outputs are byte-identical' '# THEN stage 3 runs' '# Cleanup'; do
    assert_contains "[S1] the heading is shown: $_h" "$OUT" "$_h"
done
assert_contains "[S1] ...code is still shown, the assertion marked" "$OUT" '>> assert_eq "[#1805/RHYD-1] not dispatched"'
for _c in 'A note about this file' 'resumes it' 'Thereafter' '#!/usr/bin/env bash'; do
    assert_eq "[S2] not shown: $_c" "0" "$(grep -cF -- "$_c" <<< "$OUT" || true)"
done

cat > "$R/tests/b-test.sh" <<'SH'
# setup
x=1
assert_eq "[#1805/RHYD-2] x" "1" "$x" # checks x
SH
OUT_B="$(acceptance_testfile_source "$R" tests/b-test.sh '[#1805/RHYD-2]')"
assert_eq "[S3] no headings: no comment is shown" "0" "$(grep -c '#' <<< "${OUT_B//\[#1805/}" || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
