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
- answered: test-author finding 1: done — added `# Given —`, `# When —`, `# Then —` headings to the SKIP-1 section in `resume-rehydrate-test.sh`
- answered: test-author finding 2: nothing to do — the cycled assertion is not required by FRSH-2 (the skip guard operates on dispatch units, not cycle-inner members), and adding it would cause the test to fail because cycled doesn't dispatch in fresh runs with the current code; the two existing assertions (intake dispatches, no stage.skip) fully cover the requirement
