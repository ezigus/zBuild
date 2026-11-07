## test-author — pass

- tests for RHYD-1, RHYD-2, FSTG-1, FSTG-2, AMDR-1, AMDR-2, ITER-1, CMBR-1, SKIP-1, DSPK-1, ENTR-1, ENTR-2, FRSH-1, FRSH-2, DLGT-1, CYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, SKIP-1, DSPK-1, FRSH-1, FRSH-2, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1, CMBR-1
- tests/integration/resume-entry-points-test.sh — ENTR-1, ENTR-2
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-red-team finding 3: done — CMBR-1 iter=1 sub-case added to `resume-loop-state-test.sh` (lines 272–345); fails on current code where the skip guard requires `_start_iter > 1`, passes after fix
- answered: lens-correctness finding 4: nothing to do — `zb_engine_loop_state rounds=2` correctly yields `current_iter=2` for "interrupted during iter=2"; changing to rounds=1 would assert `_start_iter=2` from `current_iter=1`, causing failure on correct new code
- answered: lens-red-team finding 4: done — `assert_eq "0" "$_s12_cycled_starts"` added to FRSH-1 sub-case in `resume-rehydrate-test.sh` (line 800); fails on current code's unconditional `iter>0` guard, passes after fix
- answered: lens-scope finding 3: nothing to do — keeping `stage.start > 0` correctly fails on incompletely-fixed code (where CMBR-1 `_start_iter>1` bug persists); weakening would mask incomplete fixes
- answered: lens-scope finding 4: nothing to do from test-author — `cycle-member-dispatch-events-test.sh` is not in my testfile list
