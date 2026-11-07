## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1, DSCYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-red-team finding 3: done — DSCMBR-1 iter=1 sub-case added to `resume-loop-state-test.sh` (lines 272–345); fails on current code where the skip guard requires `_start_iter > 1`, passes after fix
- answered: lens-correctness finding 4: nothing to do — `zb_engine_loop_state rounds=2` correctly yields `current_iter=2` for "interrupted during iter=2"; changing to rounds=1 would assert `_start_iter=2` from `current_iter=1`, causing failure on correct new code
- answered: lens-red-team finding 4: done — `assert_eq "0" "$_s12_cycled_starts"` added to DSFRSH-1 sub-case in `resume-rehydrate-test.sh` (line 800); fails on current code's unconditional `iter>0` guard, passes after fix
- answered: lens-scope finding 3: nothing to do — keeping `stage.start > 0` correctly fails on incompletely-fixed code (where DSCMBR-1 `_start_iter>1` bug persists); weakening would mask incomplete fixes
- answered: lens-scope finding 4: nothing to do from test-author — `cycle-member-dispatch-events-test.sh` is not in my testfile list
