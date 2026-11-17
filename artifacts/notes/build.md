# Build Notes — #1764 GitHub Label Claim (iteration 6)

## Status: COMPLETE

## Changes across this issue's iterations

### core/claim/claim.sh
- Iteration 4: Added _zbuild_claim_read_labels_into and _zbuild_claim_add_label_direct
  to eliminate outer subshell captures in zbuild_claim_acquire. Reduced PIDs: 468 → 463.
- Iteration 5: Wrapped plugin.sh source in a guard (_ZBUILD_CLAIM_GH_LABELS_LOADED)
  to prevent circular sourcing when unit tests load plugin.sh without _ZBUILD_ROOT.

### config/shape-change-paths.txt
- Iteration 5: Added core/claim/claim.sh (design step #5)
- Iteration 6: REMOVED core/claim/claim.sh — no SPEC requirement asks for it;
  issue-acceptance stage flagged it as an unasked-for change; acceptance-gate
  confirmed no test covers it. Removed per issue-acceptance finding 1.

## Final test results (iteration 6)
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh: 27/27 ✓
- tests/integration/teardown-repeat-signal-test.sh: 21/21 ✓
- tests/unit/lint-adr-enforced-by-test.sh: 29/29 ✓

## Why plugin.sh still sources claim.sh (circular, but required)

The unit test sources only plugin.sh (not claim.sh), then calls zbuild_claim_acquire.
So plugin.sh must still source claim.sh to make zbuild_claim_acquire available.
The claim.sh guard (_ZBUILD_CLAIM_SH_LOADED) prevents infinite recursion.
