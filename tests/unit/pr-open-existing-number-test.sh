#!/usr/bin/env bash
# tests/unit/pr-open-existing-number-test.sh — pr-open treats only a number as an
# existing PR (#2250, from the #1844 deep dive).
#
# Why: pr-open asked `gh pr list … --jq '.[0].number'` whether a PR exists and
# used ANY non-empty answer as the PR number. In #1844 run 36969128968 the
# merge-policy test's gh fake answered every call with a URL; pr-open took it as
# a number, `--argjson pr_number <url>` failed, and pr-result.json was written
# empty — which #2250's blocked check would have read as a refusal.
#
# N1 [change] a non-numeric answer means no existing PR
# N2 [guard]  a number is the existing PR
# N3 [guard]  no answer means no existing PR
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "pr-open treats only a number as an existing PR (#2250)"
setup_test_env "pr-open-existing-number"
# shellcheck source=../../plugins/tool/pr-open/plugin.sh
source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh"

_gh_says() { printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$1" > "$TEST_TEMP_DIR/bin/gh"; chmod +x "$TEST_TEMP_DIR/bin/gh"; }
_gh_says "https://github.com/o/r/pull/7"
assert_eq "[N1] a URL is not an existing PR number" "" "$(_pr_open_existing_number zbuild/issue-1 2>/dev/null)"
_gh_says "12"
assert_eq "[N2] a number is the existing PR" "12" "$(_pr_open_existing_number zbuild/issue-1 2>/dev/null)"
_gh_says ""
assert_eq "[N3] no answer → no existing PR" "" "$(_pr_open_existing_number zbuild/issue-1 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
