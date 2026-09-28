#!/usr/bin/env bash
# Tests: docs/auth.md — auth + permissions reference (issue #93)
#
# Test tier: unit  (read-only grep against committed markdown file;
# no subprocess, no network, no FS mutation, well under 1s per test)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "docs/auth.md — auth + permissions reference (issue #93)"

AUTH_DOC="$REPO_ROOT/docs/auth.md"

# ---------------------------------------------------------------------------
# TC-1: docs/auth.md exists
# ---------------------------------------------------------------------------
if [[ -f "$AUTH_DOC" ]]; then
    assert_pass "TC-1: docs/auth.md exists"
else
    assert_fail "TC-1: docs/auth.md exists" "file not found: $AUTH_DOC"
    cleanup_test_env
    print_test_results
    exit 1
fi

# ---------------------------------------------------------------------------
# TC-2: GITHUB_TOKEN section present
# ---------------------------------------------------------------------------
set +e; grep -qi "GITHUB_TOKEN" "$AUTH_DOC"; rc=$?; set -e
assert_eq "TC-2: GITHUB_TOKEN section present" "0" "$rc"

# ---------------------------------------------------------------------------
# TC-3: Personal Access Token / PAT section present
# ---------------------------------------------------------------------------
set +e; grep -qi "Personal Access Token\|PAT" "$AUTH_DOC"; rc=$?; set -e
assert_eq "TC-3: Personal Access Token (PAT) section present" "0" "$rc"

# ---------------------------------------------------------------------------
# TC-4: permissions block section present
# ---------------------------------------------------------------------------
set +e; grep -qi "permissions" "$AUTH_DOC"; rc=$?; set -e
assert_eq "TC-4: permissions section present" "0" "$rc"

# ---------------------------------------------------------------------------
# TC-5: security section present
# ---------------------------------------------------------------------------
set +e; grep -qi "security\|least.privilege\|never hardcode" "$AUTH_DOC"; rc=$?; set -e
assert_eq "TC-5: security recommendations section present" "0" "$rc"

# ---------------------------------------------------------------------------
# TC-6: required permission entries documented (contents, issues, pull-requests)
# ---------------------------------------------------------------------------
for perm in "contents" "issues" "pull-requests"; do
    set +e; grep -q "$perm" "$AUTH_DOC"; rc=$?; set -e
    assert_eq "TC-6: permission '$perm' documented" "0" "$rc"
done

# ---------------------------------------------------------------------------
# TC-7: ZBUILD_PAT secret name mentioned
# ---------------------------------------------------------------------------
set +e; grep -q "ZBUILD_PAT" "$AUTH_DOC"; rc=$?; set -e
assert_eq "TC-7: ZBUILD_PAT secret name documented" "0" "$rc"

# ---------------------------------------------------------------------------
# TC-8: doc is under 150 lines
# ---------------------------------------------------------------------------
line_count=$(wc -l < "$AUTH_DOC")
if [[ "$line_count" -le 150 ]]; then
    assert_pass "TC-8: docs/auth.md is under 150 lines ($line_count)"
else
    assert_fail "TC-8: docs/auth.md is under 150 lines" "found $line_count lines"
fi

# ---------------------------------------------------------------------------

cleanup_test_env
print_test_results
exit $((FAIL > 0))
