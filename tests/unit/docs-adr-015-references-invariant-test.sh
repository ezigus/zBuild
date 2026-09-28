#!/usr/bin/env bash
# tests/unit/docs-adr-015-references-invariant-test.sh — meta-test for #491.
#
# Ensures ADR-015 §v4 keeps referencing the cross-stage invariant test by path.
# If anyone removes the test in a later refactor but forgets to update the
# ADR, this meta-test fails — surfacing the broken contract before drift hits
# production. Mirrors the docs-adr-structure-test.sh pattern (issue #291).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "docs/adr/ADR-015 references the §v4 invariant test (issue #491)"

ADR="$REPO_ROOT/docs/adr/ADR-015-stage-io-capture.md"
INVARIANT_TEST_PATH="tests/integration/stage-io-ordering-invariant-test.sh"

# TC-1: The ADR file exists.
if [[ -f "$ADR" ]]; then
    assert_pass "TC-1: ADR-015 file exists"
else
    assert_fail "TC-1: ADR-015 file exists" "missing: $ADR"
fi

# TC-2: ADR-015 references the invariant test path in §v4 (verbatim string).
if grep -qF "$INVARIANT_TEST_PATH" "$ADR" 2>/dev/null; then
    assert_pass "TC-2: ADR-015 references invariant test path"
else
    assert_fail "TC-2: ADR-015 references invariant test path" \
        "expected substring '$INVARIANT_TEST_PATH' not found in $ADR"
fi

# TC-3: The invariant test file referenced by the ADR actually exists.
if [[ -f "$REPO_ROOT/$INVARIANT_TEST_PATH" ]]; then
    assert_pass "TC-3: invariant test file exists at the referenced path"
else
    assert_fail "TC-3: invariant test file exists" \
        "ADR references $INVARIANT_TEST_PATH but no such file in repo"
fi

# TC-4: ADR-015 has the §v4 heading (anchors the contract).
if grep -q "^### v4 — Emission ordering contract" "$ADR" 2>/dev/null; then
    assert_pass "TC-4: ADR-015 §v4 heading present"
else
    assert_fail "TC-4: ADR-015 §v4 heading present" \
        "missing '### v4 — Emission ordering contract' heading"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
