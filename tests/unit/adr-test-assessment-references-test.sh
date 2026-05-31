#!/usr/bin/env bash
# tests/unit/adr-test-assessment-references-test.sh — meta-test for #572.
#
# Asserts that ADR-018, ADR-019, ADR-020, ADR-021 each cross-reference the
# new test_assessment stage AND ADR-022, and that ADR-022 itself exists with
# the required MADR-style headings.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR amendments for test_assessment stage (issue #572)"

ADR_DIR="$REPO_ROOT/docs/adr"
ADR_018="$ADR_DIR/ADR-018-stage-invocation-modes.md"
ADR_019="$ADR_DIR/ADR-019-review-fail-closed-on-test-failure.md"
ADR_020="$ADR_DIR/ADR-020-inter-stage-data-contract.md"
ADR_021="$ADR_DIR/ADR-021-pipeline-cycle-semantics.md"
ADR_022="$ADR_DIR/ADR-022-test-assessment-stage.md"

# Helper: assert file contains a literal string.
_assert_contains() {
    local label="$1" file="$2" needle="$3"
    if [[ ! -f "$file" ]]; then
        assert_fail "$label" "file missing: $file"
        return
    fi
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        assert_pass "$label"
    else
        assert_fail "$label" "expected substring '$needle' not found in $file"
    fi
}

# TC-1..4: each amended ADR mentions test_assessment.
_assert_contains "TC-1: ADR-018 mentions test_assessment" "$ADR_018" "test_assessment"
_assert_contains "TC-2: ADR-019 mentions test_assessment" "$ADR_019" "test_assessment"
_assert_contains "TC-3: ADR-020 mentions test_assessment" "$ADR_020" "test_assessment"
_assert_contains "TC-4: ADR-021 mentions test_assessment" "$ADR_021" "test_assessment"

# TC-5..8: each amended ADR cross-references ADR-022.
_assert_contains "TC-5: ADR-018 cross-references ADR-022" "$ADR_018" "ADR-022"
_assert_contains "TC-6: ADR-019 cross-references ADR-022" "$ADR_019" "ADR-022"
_assert_contains "TC-7: ADR-020 cross-references ADR-022" "$ADR_020" "ADR-022"
_assert_contains "TC-8: ADR-021 cross-references ADR-022" "$ADR_021" "ADR-022"

# TC-9: ADR-022 file exists.
if [[ -f "$ADR_022" ]]; then
    assert_pass "TC-9: ADR-022 file exists"
else
    assert_fail "TC-9: ADR-022 file exists" "missing: $ADR_022"
fi

# TC-10..15: ADR-022 contains the required MADR-style headings.
_assert_contains "TC-10: ADR-022 has Status heading" "$ADR_022" "Status"
_assert_contains "TC-11: ADR-022 has Context heading" "$ADR_022" "## Context"
_assert_contains "TC-12: ADR-022 has Decision heading" "$ADR_022" "## Decision"
_assert_contains "TC-13: ADR-022 has Consequences heading" "$ADR_022" "## Consequences"
_assert_contains "TC-14: ADR-022 has Alternatives heading" "$ADR_022" "Alternatives"
_assert_contains "TC-15: ADR-022 has References heading" "$ADR_022" "## References"

# TC-16: ADR-022 references all four amended ADRs.
_assert_contains "TC-16a: ADR-022 references ADR-018" "$ADR_022" "ADR-018"
_assert_contains "TC-16b: ADR-022 references ADR-019" "$ADR_022" "ADR-019"
_assert_contains "TC-16c: ADR-022 references ADR-020" "$ADR_022" "ADR-020"
_assert_contains "TC-16d: ADR-022 references ADR-021" "$ADR_022" "ADR-021"

# TC-17: ADR-022 references implementation issues.
_assert_contains "TC-17a: ADR-022 references #567 (impl)" "$ADR_022" "#567"
_assert_contains "TC-17b: ADR-022 references #572 (this ADR)" "$ADR_022" "#572"

# TC-18: ADR-022 codifies the verdict enum.
_assert_contains "TC-18: ADR-022 declares verdict enum" "$ADR_022" "inconclusive"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
