# spec-correspondence checkpoint

## Files read
- design.md: 7 SPECs; SPEC-1/2/3/7 are [code]; requirement is to remove impact from delivery_loop.flow in both templates, updating stage count from 20→19 and indices.
- tests/unit/template-simple-yaml-test.sh: full file read; SPEC-18 at line 207 asserts `_TPL_CYCLE_STAGES_delivery_loop == "design_verify_cycle,build_test_cycle"`; SPEC-2 at line 82 asserts count=19; SPEC-12 at lines 277-279 asserts indices 10/15.
- tests/integration/core-pipeline-cycle-build-test-wiring-test.sh: T1 block at lines 46-84; contains `assert_eq "T1: [#1668/SPEC-3] ..." "design_verify_cycle,build_test_cycle" "${_TPL_CYCLE_STAGES_delivery_loop:-}"` at line 60-61.
- tests/integration/deployed-template-e2e-test.sh: SPEC-7 assertion at lines 105-106 asserts `_TPL_CYCLE_STAGES_delivery_loop == "design_verify_cycle,build_test_cycle"` after loading deployed.yaml at SPEC-1.

## Conclusions reached
- SPEC-1: corresponds — assertion directly checks delivery_loop.flow == "design_verify_cycle,build_test_cycle"
- SPEC-2: partial — assertions check count=19, shape-floor@10, gate-aggregator@15, but do NOT explicitly verify impact is absent from _TPL_STAGES (the full loop checking _expected_stages is in the test file but not in the shown assertion block)
- SPEC-3: corresponds — assertion block contains the exact delivery_loop roster check
- SPEC-7: corresponds — assertion directly checks deployed.yaml delivery_loop flow

## Nothing unresolved — judgement complete.
