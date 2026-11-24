#!/usr/bin/env bash
# tests/unit/lens-check-escapes-test.sh — a lens tries a check the change adds
# against the other ways its problem could be written (#2603, ADR-038).
#
# #2532: its new guard passed its own examples, and the lenses asked nothing
# more; it missed a multi-line case, files with no .sh name, "Darwin" and an
# anchored =~ — four forms of the very problem it was built to catch.
#
# CE1 [change] every lens is told: when the change adds a check whose job is to
#              catch something, list the ways the problem could be written, try
#              each against the check, and report each that gets through
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a lens tries a new check against the forms of its problem (#2603)"
setup_test_env "lens-check-escapes"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh" 2>/dev/null
for _lens in correctness red-team; do
    _p="$(_rl_build_lens_prompt "$_lens" "THE CHANGE" "" 2>/dev/null | tr -s '[:space:]' ' ')"
    assert_contains "[CE1] the $_lens lens is told to try a new check against the forms of its problem" "$_p" \
        "When the change adds a check whose job is to catch something"
    assert_contains "[CE1] ...and to report each form that gets through" "$_p" "each form that gets through is a finding"
done
cleanup_test_env
print_test_results
exit $((FAIL > 0))
