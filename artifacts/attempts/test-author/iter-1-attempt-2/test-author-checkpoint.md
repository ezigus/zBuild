## Checkpoint — issue #1668 test-author — iteration 3

### All SPECs written and verified

**tests/unit/template-simple-yaml-test.sh:**
- SPEC-18 / [#1668/SPEC-1]: assertion value is "design_verify_cycle,build_test_cycle"
- SPEC-2 / [#1668/SPEC-2]: count=19; impact removed from _expected_stages array; _impact_in_stages assertion added
- SPEC-3 (impact vars): four assertions assert empty string via :- expansion
- SPEC-12 / [#1668/SPEC-2]: indices [10]=shape-floor, [15]=gate-aggregator
- SPEC-13: impact assertion deleted

**tests/integration/core-pipeline-cycle-build-test-wiring-test.sh:**
- T1 / [#1668/SPEC-3]: "design_verify_cycle,build_test_cycle"

**tests/integration/deployed-template-e2e-test.sh:**
- [#1668/SPEC-7]: "design_verify_cycle,build_test_cycle" for deployed.yaml

**tests/unit/impact-max-turns-test.sh (SPEC-8) — DONE in iteration 3:**
- Removed load_template simple.yaml
- Added inline fixture with impact stage (roles: [impact_analyzer], max_turns: 45, timeout_s: 600)
- Tagged all three assertions with [#1668/SPEC-8]
- shellcheck clean, no SIGPIPE issues

**tests/unit/template-always-run-test.sh (SPEC-9) — DONE in iteration 3:**
- SPEC-2 count: "20" → "19"
- Comment updated to reference #1668 impact removal
- Added [#1668/SPEC-9] tag to assertion label

### Shape-floor findings: all out of scope for test-author
Files listed (golden files, shape-floor-content-stable-test.sh, etc.) are not in the
test-author's testfile list. These are outside test-author's Write authority.

### All work complete — nothing left to do
