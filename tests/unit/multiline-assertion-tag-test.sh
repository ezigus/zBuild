#!/usr/bin/env bash
# tests/unit/multiline-assertion-tag-test.sh — a test check written over several
# lines counts as tagged when its label is on any of them (#2460).
#
# Why: test-author writes long checks with a backslash, the label on the next
# line (`assert_contains \` then `"[#1805/SPEC-3] …" …`). The checker only
# counted a check whose `assert…` and tag shared one line, called those checks
# untagged, and raised "only part of the requirement" findings that were false
# — 3 of 4 on #1805 run 41546214211.
#
# M1 [change] the stanza for a SPEC includes a check whose tag is on a continued
#             line, every line of it marked >>
# M2 [change] the whole-file view marks every line of such a check >>
# M3 [change] the label readout finds the check, label and all
# M4 [guard]  a check whose tag is on its own line is still found, and a tag in
#             a comment or a plain string is not a check
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../scripts/lib/acceptance-coverage.sh
source "$REPO_ROOT/scripts/lib/acceptance-coverage.sh"
print_test_header "a check over several lines counts as tagged (#2460)"
setup_test_env "multiline-assertion-tag"
export ZBUILD_ISSUE="$(zb_test_issue)"
TAG3="$(acceptance_spec_tag SPEC-3)"; TAG4="$(acceptance_spec_tag SPEC-4)"

R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/tests"
cat > "$R/tests/x-test.sh" <<T
#!/usr/bin/env bash
out="\$(run_it)"
assert_contains \\
    "$TAG3 restored artifact has the original payload" \\
    "\$out" "payload"

rc=1
assert_eq "$TAG4 exits 1" "1" "\$rc"
# $TAG3 a comment is not a check
echo "$TAG3 a string is not a check"
T

_src="$(acceptance_find_assertion_sources "$R" SPEC-3 tests/x-test.sh)"
assert_contains "[M1] the stanza holds the check whose tag is on a continued line" "$_src" "restored artifact has the original payload"
assert_contains "[M1] ...its first line is marked" "$_src" ">> assert_contains \\"
assert_contains "[M1] ...and its tagged line" "$_src" ">> \"$TAG3 restored artifact"
assert_contains "[M1] ...and its last line" "$_src" '>> "$out" "payload"'

_whole="$(acceptance_testfile_source "$R" tests/x-test.sh "$TAG3")"
assert_contains "[M2] the whole-file view marks the check's first line" "$_whole" ">> assert_contains \\"
assert_contains "[M2] ...and its tagged line" "$_whole" ">> \"$TAG3 restored artifact"
if grep -qF ">> echo" <<< "$_whole"; then assert_fail "[M4] a string is not a check" "it was marked"; else assert_pass "[M4] a string is not a check"; fi

_lbl="$(acceptance_find_assertion_label "$R" SPEC-3 tests/x-test.sh)"
assert_contains "[M3] the label readout finds the check over several lines" "$_lbl" "restored artifact has the original payload"
assert_contains "[M3] ...starting at its assert call" "$_lbl" "assert_contains"

_src4="$(acceptance_find_assertion_sources "$R" SPEC-4 tests/x-test.sh)"
assert_contains "[M4] a one-line check is still found and marked" "$_src4" ">> assert_eq \"$TAG4 exits 1\""

cleanup_test_env
print_test_results
exit $((FAIL > 0))
