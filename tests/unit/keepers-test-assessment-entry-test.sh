#!/usr/bin/env bash
# tests/unit/keepers-test-assessment-entry-test.sh — meta-test for #572.
#
# Asserts that docs/KEEPERS.md gains an entry naming test_assessment under
# Section A and cross-references ADR-022.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "KEEPERS.md entry for test_assessment (issue #572)"

KEEPERS="$REPO_ROOT/docs/KEEPERS.md"

# TC-1: KEEPERS.md exists.
if [[ -f "$KEEPERS" ]]; then
    assert_pass "TC-1: KEEPERS.md exists"
else
    assert_fail "TC-1: KEEPERS.md exists" "missing: $KEEPERS"
fi

# TC-2: KEEPERS.md mentions test_assessment.
if grep -qF "test_assessment" "$KEEPERS" 2>/dev/null; then
    assert_pass "TC-2: KEEPERS.md mentions test_assessment"
else
    assert_fail "TC-2: KEEPERS.md mentions test_assessment" \
        "no 'test_assessment' substring in KEEPERS.md"
fi

# TC-3: KEEPERS.md cross-references ADR-022 from the entry.
if grep -qF "ADR-022" "$KEEPERS" 2>/dev/null; then
    assert_pass "TC-3: KEEPERS.md cross-references ADR-022"
else
    assert_fail "TC-3: KEEPERS.md cross-references ADR-022" \
        "no 'ADR-022' substring in KEEPERS.md"
fi

# TC-4: the test_assessment entry sits under Section A.
# Heuristic: between '## Section A' header and the next top-level '## Section'.
if awk '
    /^## Section A/ {in_a=1; next}
    /^## Section [B-Z]/ {in_a=0}
    in_a && /test_assessment/ {found=1}
    END {exit found?0:1}
' "$KEEPERS"; then
    assert_pass "TC-4: test_assessment entry under Section A"
else
    assert_fail "TC-4: test_assessment entry under Section A" \
        "test_assessment not found inside Section A range"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
