## Checkpoint — issue #1668 test-author — iteration 2

### All SPECs written (carried from iteration 1)

**tests/unit/template-simple-yaml-test.sh:**
- SPEC-18 / [#1668/SPEC-1]: assertion value is "design_verify_cycle,build_test_cycle"; label is "[SPEC-18] [#1668/SPEC-1]"
- SPEC-2 / [#1668/SPEC-2]: count=19; impact removed from _expected_stages array; indices [10]=shape-floor, [15]=gate-aggregator
- SPEC-3 (impact vars): four assertions use `:-` expansion asserting empty string
- SPEC-12 / [#1668/SPEC-2]: indices [10] shape-floor, [15] gate-aggregator correct
- SPEC-13: impact assertion deleted; comment updated

**tests/integration/core-pipeline-cycle-build-test-wiring-test.sh:**
- T1: [#1668/SPEC-3] assertion value is "design_verify_cycle,build_test_cycle"

**tests/integration/deployed-template-e2e-test.sh:**
- [#1668/SPEC-7] assertion added after SPEC-1 load

### Iteration 2 work

**spec-correspondence finding 1**: Added explicit `_impact_in_stages` assertion in SPEC-2 section
of template-simple-yaml-test.sh so that `impact` absent from `_TPL_STAGES` is directly verifiable.

### Out-of-scope findings (answered nothing to do)
- test finding 1: impact-max-turns-test.sh — not in testfile scope
- test finding 2: template-always-run-test.sh — not in testfile scope
- shape-floor finding 1: golden/full-pipeline/event-sequence.golden — not in testfile scope
- shape-floor finding 2: golden/parity/event-sequence.golden — not in testfile scope
- issue-acceptance finding 1: impact-max-turns-test.sh — not in testfile scope
- issue-acceptance finding 2: dogfood blocked by non-in-scope failing tests

### Nothing left to do for test-author
