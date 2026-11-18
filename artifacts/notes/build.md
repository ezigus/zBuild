# Build Notes — #1764 GitHub Label Claim (iteration 8)

## Status: COMPLETE — no new changes needed

## Iteration 8 resolution

The two build findings from iteration 7 were about incorrect step quotes:
- step 2: quoted partial line (missing "Default cross-machine..." prefix)
- step 9: quoted first line of bullet (missing "- " prefix)

Both steps answered "not needed" — changes already committed in prior iterations.
git diff HEAD is empty; all 3 test suites pass (27/27, 22/22, 29/29).

---

## Status: COMPLETE

## Changes across this issue's iterations

### core/claim/claim.sh
- Iteration 4: Added _zbuild_claim_read_labels_into and _zbuild_claim_add_label_direct
  to eliminate outer subshell captures in zbuild_claim_acquire.
- Iteration 5: Wrapped plugin.sh source in a guard (_ZBUILD_CLAIM_GH_LABELS_LOADED)
  to prevent circular sourcing when unit tests load plugin.sh without _ZBUILD_ROOT.

### config/shape-change-paths.txt
- Iteration 5: Added core/claim/claim.sh (design step #5)
- Iteration 6: REMOVED core/claim/claim.sh — no SPEC asks for it.

### plugins/claim-coordinator/github-labels/README.md (iteration 7)
- Changed description from claimed:<machine> to zbuild:claimed
- Updated TOCTOU section (removed claimed:* reference)
- Updated ZBUILD_CLAIM_MACHINE_ID row: now says "holder string only, not label name"

### docs/adr/ADR-005-claim-coordinator.md (iteration 7)
- §1 Enforced by bullet: added DSCLA-3 (claim-coordinator-unit-test.sh) and DSCLA-9
  (teardown-repeat-signal-test.sh) for §1(c) refused behavior
- §2 Enforced by bullet: added DSCLA-12 for CI holder rendering

### docs/adr/ADR-059-issue-vs-run-keying.md (iteration 7)
- Enforced by section: added §4 cross-machine exclusion entry naming DSCLA-3

## Why plugin.sh still sources claim.sh (circular, but required)

The unit test sources only plugin.sh (not claim.sh), then calls zbuild_claim_acquire.
So plugin.sh must still source claim.sh to make zbuild_claim_acquire available.
The claim.sh guard (_ZBUILD_CLAIM_SH_LOADED) prevents infinite recursion.

## Final test results (iteration 7)
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh: 27/27 ✓
- tests/integration/teardown-repeat-signal-test.sh: 22/22 ✓
- tests/unit/lint-adr-enforced-by-test.sh: 29/29 ✓
