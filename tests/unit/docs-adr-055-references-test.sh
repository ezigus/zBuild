#!/usr/bin/env bash
# tests/unit/docs-adr-055-references-test.sh — meta-test for #1820 (ADR-055).
#
# Ensures ADR-055 exists and references the keystone integration test and ADR-006.
# Mirrors docs-adr-020-references-test.sh from #496.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "docs/adr/ADR-055 inter-stage data contract v2 — content conformance (issue #1820)"

ADR="$REPO_ROOT/docs/adr/ADR-055-inter-stage-data-contract-v2.md"
KEYSTONE_TEST="tests/integration/pipeline-preflight-missing-stage-test.sh"

# TC-1 [SPEC-2]: ADR-055 file exists.
if [[ -f "$ADR" ]]; then
    assert_pass "[SPEC-2] TC-1: ADR-055 file exists"
else
    assert_fail "[SPEC-2] TC-1: ADR-055 file exists" "missing: $ADR"
    cleanup_test_env
    print_test_results
    exit 1
fi

# TC-2 [SPEC-3]: ADR-055 references the keystone pre-flight integration test.
set +e
grep -qF "$KEYSTONE_TEST" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-3] TC-2: ADR-055 references keystone test path" "0" "$rc"

# TC-3 [SPEC-3]: Keystone test exists on disk.
if [[ -f "$REPO_ROOT/$KEYSTONE_TEST" ]]; then
    assert_pass "[SPEC-3] TC-3: keystone test file exists at referenced path"
else
    assert_fail "[SPEC-3] TC-3: keystone test file exists" \
        "ADR-055 references $KEYSTONE_TEST but no such file"
fi

# TC-4 [SPEC-7]: ADR-055 cross-references ADR-006 (resume contract, preflight_failed).
set +e
grep -qE "ADR-006" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-7] TC-4: ADR-055 cross-references ADR-006" "0" "$rc"

# TC-5 [SPEC-7]: the consumer declares the artifact NAME and nothing else.
#
# #1768 amended ADR-055 §1: this asserted `from: <producer-stage>.<output_id>`,
# the form where a consumer names its producer. That was removed — the producer
# name is redundant given output-id uniqueness (§5) and could not express a
# backwards edge, which is what forced the untyped `source: artifacts` hatch.
#
# Asserted as a PAIR: the new form is present AND the retired one is gone.
# Presence alone would still pass if both forms were documented, which is the
# ambiguity the amendment exists to remove.
set +e
grep -qE '^ *- id: <output-id> +# the same artifact name' "$ADR" 2>/dev/null
_has_new=$?
grep -qE '^ *- from: <producer-stage>\.<output_id>' "$ADR" 2>/dev/null
_has_old=$?
set -e
_tc5="new=$([[ $_has_new -eq 0 ]] && echo yes || echo no) old_gone=$([[ $_has_old -ne 0 ]] && echo yes || echo no)"
assert_eq "[SPEC-7] TC-5: consumer declares the artifact name, and the from: form is gone" \
    "new=yes old_gone=yes" "$_tc5"

# TC-5b [SPEC-7]: the consumer names no producer stage. The property that makes
# a plugin portable across templates (ADR-042), and the reason the amendment
# happened at all.
set +e
grep -q "It names no other stage" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-7] TC-5b: ADR-055 states a stage names no other stage" "0" "$rc"

# TC-6 [SPEC-7]: a consumer never restates path or type — the property that
# stopped scope-manifest.md being declared three times with two different types.
set +e
grep -q "never restates" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-7] TC-6: ADR-055 states a consumer never restates path or type" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
