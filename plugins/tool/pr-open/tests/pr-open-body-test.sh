#!/usr/bin/env bash
# plugins/tool/pr-open/tests/pr-open-body-test.sh — the PR body says what the PR
# is for (#2368 part 2, ADR-040).
#
# Why: the body carried the merged review report — every lens finding — which
# made it a review log rather than a description. Each lens's output is a run
# artifact every later stage already sees; the body describes the change.
#
#   B1 [change] the body names the issue, the goal, each work item, the files
#               changed and the test result
#   B2 [change] it carries no review findings or advisory-review section
#   B3 [guard]  values from the plan are escaped (no raw HTML)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the PR body says what the PR is for (#2368)"
assert_not_contains() {
    if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "found: $3"; else assert_pass "$1"; fi
}
setup_test_env "pr-open-body"
# shellcheck source=../plugin.sh
source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh" >/dev/null 2>&1

PLAN="$TEST_TEMP_DIR/plan.json"
jq -n '{goal:"Retry uploads <b>twice</b>", steps:[{id:"step-1",description:"add the retry"},{id:"step-2",description:"test the retry"}]}' > "$PLAN"
_body="$(_pr_open_compose_body 42 "$PLAN" pass $'src/upload.sh\ntests/upload-test.sh' "" false)"

print_test_section "B1: what the PR is for"
assert_contains "[B1] closes the issue" "$_body" "Closes #42"
assert_contains "[B1] the goal" "$_body" "Retry uploads"
assert_contains "[B1] each work item" "$_body" "- add the retry"
assert_contains "[B1] ...every one" "$_body" "- test the retry"
assert_contains "[B1] the files changed" "$_body" "- src/upload.sh"
assert_contains "[B1] the test result" "$_body" "**Tests:** pass"

print_test_section "B2: no review findings"
assert_not_contains "[B2] no advisory-review section" "$_body" "Advisory review"
assert_not_contains "[B2] no review verdict" "$_body" "Review verdict"

print_test_section "B3: escaped"
assert_not_contains "[B3] no raw HTML from the plan" "$_body" "<b>"
assert_contains "[B3] ...it is escaped, not dropped" "$_body" '\<b\>twice'


cleanup_test_env
print_test_results
exit $((FAIL > 0))
