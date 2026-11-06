## test-author — pass

- changed 1 test file(s); acceptance assertions for 14 SPEC(s) from the design contract

- SPECs in the contract: 14
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, SKIP-1, DSPK-1, FRSH-1, FRSH-2, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done** — Added two `assert_contains` assertions in the AMDR-2 section of `resume-rehydrate-test.sh` (after line 604), asserting that `_adr050_s6` (§6 of ADR-050) contains `"resume-rehydrate-test.sh"` and `"resume-entry-points-test.sh"` by name. A §6 that adds the boundary prose but omits the Enforced-by update would still pass the original three assertions but fail these two — which is exactly what the finding required.
- answered: test-author finding 2: done** — Added `assert_gt "[#1805/FRSH-2] fresh run dispatches cycled (inner member of cyc; every stage emits stage.start, not just intake)" "$_frsh2_cycled_starts" "0"` in the FRSH-2 section of `resume-rehydrate-test.sh` (after the "no stage.skip" assertion). The fixture `artifact-snapshot-coverage` has `intake` (leaf) and `cyc` (cycle, dispatching `cycled`). Asserting `_frsh2_cycled_starts > 0` proves every stage dispatched, not just one — fulfilling the requirement that "every stage emits a stage.start event".
