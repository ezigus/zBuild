## test-author — unusable

- changed 3 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- SPECs in the contract: 11
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, BNDY-1, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done** — Added one `assert_contains` to the AMDR-1 section in `resume-rehydrate-test.sh` checking for the phrase `"not to be combined with dispatch-loop changes"`. The previous round answered about RHYD-1 by mistake; this clause was genuinely absent.
- answered: test-author finding 2: done** — In `resume-loop-state-test.sh`:
- answered: test-author finding 3: done** — In `resume-entry-points-test.sh`, added `pipeline.resume` event ordering assertions for all three ENTR-1 paths:
