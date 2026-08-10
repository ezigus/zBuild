#!/usr/bin/env bash
# tests/unit/docs-adr-020-references-test.sh — meta-test for #496 (ADR-020).
#
# Ensures ADR-020 keeps referencing the keystone integration test by path.
# Mirrors docs-adr-015-references-invariant-test.sh from #491.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "docs/adr/ADR-020 references the keystone pre-flight test (issue #496)"

ADR="$REPO_ROOT/docs/adr/ADR-020-inter-stage-data-contract.md"
KEYSTONE_TEST="tests/integration/pipeline-preflight-missing-stage-test.sh"

# TC-1: ADR file exists.
if [[ -f "$ADR" ]]; then
    assert_pass "TC-1: ADR-020 file exists"
else
    assert_fail "TC-1: ADR-020 file exists" "missing: $ADR"
fi

# TC-2: ADR-020 references the keystone test path.
if grep -qF "$KEYSTONE_TEST" "$ADR" 2>/dev/null; then
    assert_pass "TC-2: ADR-020 references keystone test path"
else
    assert_fail "TC-2: ADR-020 references keystone test path" \
        "expected substring '$KEYSTONE_TEST' not found"
fi

# TC-3: Keystone test exists.
if [[ -f "$REPO_ROOT/$KEYSTONE_TEST" ]]; then
    assert_pass "TC-3: keystone test file exists at referenced path"
else
    assert_fail "TC-3: keystone test file exists" \
        "ADR references $KEYSTONE_TEST but no such file"
fi

# TC-4: ADR-020 documents the external sources allowlist.
if grep -q "External Sources Allowlist\|external sources allowlist\|External sources allowlist" "$ADR" 2>/dev/null; then
    assert_pass "TC-4: ADR-020 documents external sources allowlist"
else
    assert_fail "TC-4: ADR-020 documents external sources allowlist" \
        "expected 'external sources allowlist' (any case) section in $ADR"
fi

# TC-5: ADR-020 cross-references ADR-006.
if grep -qE "ADR-006" "$ADR" 2>/dev/null; then
    assert_pass "TC-5: ADR-020 cross-references ADR-006"
else
    assert_fail "TC-5: ADR-020 cross-references ADR-006" "no ADR-006 reference"
fi

# TC-6: ADR-006 was amended with preflight_failed.
if grep -q "preflight_failed" "$REPO_ROOT/docs/adr/ADR-006-resume-contract.md" 2>/dev/null; then
    assert_pass "TC-6: ADR-006 amended with preflight_failed enum"
else
    assert_fail "TC-6: ADR-006 amended with preflight_failed enum" \
        "expected 'preflight_failed' substring in ADR-006"
fi

# TC-7 [SPEC-9]: ADR-020 is marked Superseded (by ADR-055, #1820).
# Fails at baseline (Status was "Proposed") and passes once the superseded header is added.
if grep -qE "Superseded" "$ADR" 2>/dev/null; then
    assert_pass "[SPEC-9][change] TC-7: ADR-020 is marked Superseded"
else
    assert_fail "[SPEC-9][change] TC-7: ADR-020 is marked Superseded" \
        "expected 'Superseded' in Status header of $ADR"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
