# Build Notes — #1764 GitHub Label Claim (iteration 5)

## Status: COMPLETE

## Changes across this issue's iterations

### core/claim/claim.sh (key iteration 4+5 changes)
- Iteration 4 (agent): Added _zbuild_claim_read_labels_into and _zbuild_claim_add_label_direct
  to eliminate outer subshell captures in zbuild_claim_acquire. Reduced PIDs: 468 → 463.
- Iteration 5 (this): Wrapped plugin.sh source in a guard:
    if [[ -z "${_ZBUILD_CLAIM_GH_LABELS_LOADED:-}" ]]; then
        source "${_ZBUILD_ROOT}/plugins/..."
    fi
  When loaded via plugin.sh chain (unit test path), _ZBUILD_CLAIM_GH_LABELS_LOADED is set
  → skips the source, no _ZBUILD_ROOT required. Fixes "unbound variable" error in unit test.

## Why plugin.sh still sources claim.sh (circular, but required)

The unit test sources only plugin.sh (not claim.sh), then calls zbuild_claim_acquire.
So plugin.sh must still source claim.sh to make zbuild_claim_acquire available.
The claim.sh guard (_ZBUILD_CLAIM_SH_LOADED) prevents infinite recursion.

## Final test results
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh: 27/27 ✓
- tests/integration/teardown-repeat-signal-test.sh: 21/21 ✓
- tests/unit/lint-adr-enforced-by-test.sh: 29/29 ✓
- tests/e2e/fork-budget-test.sh: 21/21 ✓ (463 startup processes ≤ 465 budget)
