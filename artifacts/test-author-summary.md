## test-author — pass

- tests for RHYD-1, RHYD-2, FSTG-1, FSTG-2, AMDR-1, AMDR-2, ITER-1, CMBR-1, SKIP-1, DSPK-1, ENTR-1, ENTR-2, FRSH-1, FRSH-2, DLGT-1, CYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, SKIP-1, DSPK-1, FRSH-1, FRSH-2, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1, CMBR-1
- tests/integration/resume-entry-points-test.sh — ENTR-1, ENTR-2
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test finding 1: nothing to do — CMBR-1 test is correct; it fails because `_cycle_iter_dispatch` has no member-skip logic. Code fix needed.
- answered: test finding 2: done — removed the unreachable `_frsh2_cycled_starts == 1` assertion from resume-rehydrate-test.sh FRSH-2 section; cycled fails plugin resolution before stage.start is ever emitted.
- answered: acceptance-gate finding 1: nothing to do (test scope) — CMBR-1 fails because the code has not implemented member-skip logic in `_cycle_iter_dispatch`. The test is correct.
