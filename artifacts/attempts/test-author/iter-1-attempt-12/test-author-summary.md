## test-author — unusable

- changed 1 test file(s); 3 finding(s) about its assertions are open — the next try fixes them

- SPECs in the contract: 12
- assertions are authored from the SPEC text, never from the implementation
- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, FRSH-1, BNDY-1, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: nothing to do — `resume-loop-state-test.sh` lines 105–144 already contain the `[#1805/ITER-1]`-tagged guard sub-test for nested-loop re-entries. Present and correct.
- answered: test-author finding 2: nothing to do — BNDY-1 is a no-code structural requirement that this FILE contains both resume-side assertions (RHYD-1/RHYD-2 at the top) and a fresh-run sub-case (BNDY-1 section). Both sides exist in the file; a test cannot assert that another assertion coexists in the same file — the structural property is satisfied by the file's content.
