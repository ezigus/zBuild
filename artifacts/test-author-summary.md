## test-author — pass

- changed 1 test file(s); acceptance assertions for 12 SPEC(s) from the design contract

- SPECs in the contract: 12
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, DSPK-1, FRSH-1, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — added `# Given`, `# When`, `# Then` section heading comments to the `[#1805/DLGT-1]` block in `tests/unit/hydrate-stage-test.sh`. The `# Given` is placed before the sentinel function definition and state setup, `# When` before the `hydrate_run` call, and `# Then` before `assert_file_exists`.
