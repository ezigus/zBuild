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

# Every assertion below anchors to a code fence or a leading table cell. A bare
# grep for a contract word is inert here: "run", "cleanup", "pass", "fail" and
# "error" all occur in ordinary prose, so a bare-word check passes on any
# technical document and would survive deleting the section it claims to pin.

# TC-3 [SPEC-5]: the two hook signatures, including resolved_inputs and scope.
for sig in "run(stage_id, state_file, resolved_inputs)" "cleanup(stage_id, state_file, scope)"; do
    set +e
    grep -qF "$sig" "$ADR" 2>/dev/null
    rc=$?
    set -e
    assert_eq "[SPEC-5] TC-3: ADR-054 specifies '$sig'" "0" "$rc"
done

# TC-4 [SPEC-6]: the disposition vocabulary is the engine-response set, NOT the
# verdict class. pass|warn|fail|error is the verdict class; naming it
# "disposition" is the confusion this ADR exists to end, so assert the six words
# that each carry a distinct engine response.
for disposition in complete interrupted throttled exhausted unavailable broken; do
    set +e
    grep -q "^| \`$disposition\` |" "$ADR" 2>/dev/null
    rc=$?
    set -e
    assert_eq "[SPEC-6] TC-4: ADR-054 tabulates disposition '$disposition'" "0" "$rc"
done

# TC-5 [SPEC-6]: the result file's version key is result_contract, not
# schema_version — schema_version is the artifact's OWN schema (build-summary.json
# has been at 4 since #602), and conflating them reinterprets every artifact.
set +e
grep -q "^| \`result_contract\` |" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-6] TC-5: ADR-054 tabulates result_contract as the version key" "0" "$rc"

# TC-6 [SPEC-6]: cleanup carries a scope, and release never deletes. An
# abort-only cleanup is what forces every plugin to invent a second teardown path.
for scope in release purge; do
    set +e
    grep -q "^| \`$scope\` |" "$ADR" 2>/dev/null
    rc=$?
    set -e
    assert_eq "[SPEC-6] TC-6: ADR-054 tabulates cleanup scope '$scope'" "0" "$rc"
done

# TC-7 [SPEC-4]: valid_verdicts is recorded as a gap to CLOSE (#1708), not a
# field to delete — the engine reads it under this contract.
set +e
grep -q "1708" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-4] TC-7: ADR-054 cites #1708 for valid_verdicts enforcement" "0" "$rc"

# TC-10 [SPEC-6]: rc is binary on EVERY path, engine-internal included. Exempting
# the engine would leave an undeclared integer vocabulary — the exact defect this
# ADR removes — one layer down. #1823 owns re-homing route_back and the
# blocking-member halt onto declared channels.
set +e
grep -qE "engine-internal paths too|not only at the plugin boundary" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-6] TC-10: ADR-054 binds rc {0,1} on engine-internal paths" "0" "$rc"

# TC-9 [SPEC-4]: the ADR carries WHY this contract precedes the rest of the
# initiative — 59 issues across Phases 1-7 cite it, and the ordering constraint is
# the thing they most need. Phase 1 (#1794) makes a failing stage terminal; without
# the disposition split a router timeout on intake becomes a dead run. A contract
# stating only its rules, not the consequence of skipping it, gets skipped.
set +e
grep -q "#1794" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-4] TC-9: ADR-054 names the Phase 1 dependency it gates" "0" "$rc"

set +e
grep -qiE "transient|timed out|timeout on .intake|network hiccup" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-4] TC-9: ADR-054 states the transient-vs-broken consequence" "0" "$rc"

# TC-8 [SPEC-4]: ADR-056 already owns the init/finalize deletion and the hook
# lifecycle. Two Accepted ADRs must not independently specify the same surface.
set +e
grep -q "ADR-056" "$ADR" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-4] TC-8: ADR-054 defers the hook lifecycle to ADR-056" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
