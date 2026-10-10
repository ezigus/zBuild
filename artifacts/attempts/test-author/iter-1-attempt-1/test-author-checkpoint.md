## Checkpoint — issue #1668 test-author — COMPLETE

### All SPECs written

**tests/unit/template-simple-yaml-test.sh:**
- SPEC-18 / [#1668/SPEC-1]: changed assertion value from "design_verify_cycle,impact,build_test_cycle" to "design_verify_cycle,build_test_cycle"; label updated to "[SPEC-18] [#1668/SPEC-1]"
- SPEC-2 / [#1668/SPEC-2]: count changed 20→19; `impact` removed from _expected_stages array; label updated to "[SPEC-2] [#1668/SPEC-2]"
- SPEC-3 (impact vars): four assertions changed from asserting values (impact_analyzer, file,stdout, 600, 45) to asserting empty string with `:-` expansion (unset)
- SPEC-12 / [#1668/SPEC-2]: indices updated [11]→[10] for shape-floor, [16]→[15] for gate-aggregator; labels include [#1668/SPEC-2]
- SPEC-13: `_TPL_STAGES[6] == impact` assertion deleted; comment updated to note impact removed

**tests/integration/core-pipeline-cycle-build-test-wiring-test.sh:**
- T1: assertion value changed from "design_verify_cycle,impact,build_test_cycle" to "design_verify_cycle,build_test_cycle"; label updated to include [#1668/SPEC-3]

**tests/integration/deployed-template-e2e-test.sh:**
- New [#1668/SPEC-7] assertion added after SPEC-1 load: asserts `_TPL_CYCLE_STAGES_delivery_loop` == "design_verify_cycle,build_test_cycle"

### Nothing left to do — all SPECs covered
