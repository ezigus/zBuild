#!/usr/bin/env bash
# tests/unit/docs-adr-054-references-test.sh — meta-test for #1820 (ADR-054).
#
# Ensures ADR-054 exists and references the key contracts it codifies.
# Mirrors docs-adr-020-references-test.sh from #496.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "docs/adr/ADR-054 stage contract — content conformance (issue #1820)"

ADR="$REPO_ROOT/docs/adr/ADR-054-stage-contract.md"

# TC-1 [SPEC-1]: ADR-054 file exists.
if [[ -f "$ADR" ]]; then
    assert_pass "[SPEC-1] TC-1: ADR-054 file exists"
else
    assert_fail "[SPEC-1] TC-1: ADR-054 file exists" "missing: $ADR"
    cleanup_test_env
    print_test_results
    exit 1
fi

# TC-2 [SPEC-4]: ADR-054 references ADR-001 (amends it).
set +e
grep -qE "ADR-001" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-4] TC-2: ADR-054 references ADR-001" "0" "$rc"

# TC-3 [SPEC-5]: ADR-054 documents the hook signature (stage_id, state_file).
set +e
grep -q "stage_id" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-5] TC-3: ADR-054 documents stage_id hook argument" "0" "$rc"

set +e
grep -q "state_file" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-5] TC-3: ADR-054 documents state_file hook argument" "0" "$rc"

# TC-4 [SPEC-6]: ADR-054 documents the disposition vocabulary (pass, warn, fail, error).
for disposition in pass warn fail error; do
    set +e
    grep -q "$disposition" "$ADR" 2>/dev/null
    rc=$?
    set -e
    assert_eq "[SPEC-6] TC-4: ADR-054 documents disposition '$disposition'" "0" "$rc"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
