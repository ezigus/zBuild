#!/usr/bin/env bash
# Guard: #1719 removed the claude-code-review outcome summary comment. Its
# "N comment(s) posted" was a running total of every reviewer comment on the
# PR, never this run's, and the rest of the comment said nothing the review
# itself does not. Nothing may reintroduce a post-review summary poster.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "claude-code-review has no outcome summary comment (#1719)"

WF="$REPO_ROOT/.github/workflows/claude-code-review.yml"

assert_eq "[SPEC-1] the workflow has no 'Post review outcome comment' step" "0" \
    "$(grep -c 'Post review outcome comment' "$WF")"
assert_eq "[SPEC-1] the workflow does not source ci-review-outcome.sh" "0" \
    "$(grep -c 'ci-review-outcome' "$WF")"

assert_file_not_exists "[SPEC-2] scripts/lib/ci-review-outcome.sh is removed" \
    "$REPO_ROOT/scripts/lib/ci-review-outcome.sh"
assert_file_not_exists "[SPEC-2] its test is removed with it" \
    "$REPO_ROOT/tests/unit/claude-code-review-outcome-test.sh"

# The verdict marker existed only to feed the removed summary; nothing reads it now.
assert_eq "[SPEC-3] the prompt no longer asks for a <!-- verdict: --> marker" "0" \
    "$(grep -c 'verdict:' "$WF")"

print_test_results
exit $((FAIL > 0))
