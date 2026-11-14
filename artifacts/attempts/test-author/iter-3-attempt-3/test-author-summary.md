## test-author — unusable

- changed 1 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/unit/platform-probe-test.sh — DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-3
- tests/unit/atomic-write-cost-test.sh — DSBUD-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — added `export ZBUILD_PLATFORM=macos` before the `source "$REPO_ROOT/scripts/lib/compat.sh"` call in the DSPRB-1 subshell; compat.sh overwrites it on Linux CI, so a second assignment after source keeps ZBUILD_PLATFORM=macos at call time, distinguishing old code (reads at call time → BSD form → error) from new code (uses probe set at load time → GNU form → success)
- answered: test-author finding 2: done — same fix as finding 1 applied to the DSPRB-2 subshell: `export ZBUILD_PLATFORM=macos` added before `source "$REPO_ROOT/scripts/lib/helpers.sh"`
- answered: test-author finding 3: done — replaced the call-log / recording-stat approach with direct inspection of `_ZB_STAT_MODE_CMD` after sourcing helpers.sh; `assert_contains "$_dsprb3_cmd" "-c"` fails when base code leaves the variable unset (empty) and passes when new code sets it to `"-c"`
- answered: test-author finding 4: done — replaced the sed call-count approach with direct inspection of `_ZB_SED_INPLACE_ARGS` (the array the working copy declares); previous attempt used wrong scalar name `_ZB_SED_INPLACE_CMD`; fixed test uses `declare -p` + `${#_ZB_SED_INPLACE_ARGS[@]}` to check array is declared and non-empty; base code → not declared → len=0 → fails; new code → `(-i)` → len=1 → passes
- answered: test-author finding 5: wrong — the two claims in DSBUD-1 are verified in different ways: (1) "fork-budget-test.sh still passes" is verified by the test suite running fork-budget-test.sh independently (it cannot be run from within a unit test without triggering the re-entrancy guard in test-helpers.sh line 34); (2) "stat probe runs once at library load, adding no per-atomic_write process cost" is verified by W1's sorted-CALLS assertion (`"cat mv stat"` = exactly one stat per `atomic_write`), which is the specific fork-budget concern the probe change could affect
- answered: acceptance-gate finding 1: wrong — tags `[DSPRB-1]` through `[DSADR-3]` are present in `tests/unit/platform-probe-test.sh` assertion labels, and `[DSBUD-1]` is in `atomic-write-cost-test.sh` W1; the "Already written" section confirms the tags were found by the script
- answered: acceptance-gate finding 2: wrong — `tests/unit/platform-probe-test.sh` carries tagged assertions for `scripts/lib/compat.sh` (DSPRB-1, DSPRB-5, DSDEL-1, DSADR-3) and `scripts/lib/helpers.sh` (DSPRB-2, DSPRB-3, DSPRB-4); reverting either file would turn those tests red
- not answered: issue-acceptance finding 1
- not answered: issue-acceptance finding 2
- not answered: issue-acceptance finding 3
- not answered: issue-acceptance finding 4
- not answered: issue-acceptance finding 5
- not answered: issue-acceptance finding 6
- not answered: issue-acceptance finding 7
