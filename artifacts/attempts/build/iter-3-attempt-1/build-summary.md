## build — pass

- changed no file

- over 1 pass(es), 1 iteration(s)
- answered: acceptance-gate finding 1: wrong — not reproduced: `[DSPRB-1]` through `[DSADR-3]` are present in `tests/unit/platform-probe-test.sh` (lines 46–219) and `[DSBUD-1]` is in `tests/unit/atomic-write-cost-test.sh` (line 48, as `[W1][DSBUD-1]`); running both files shows all 9 and all 14 assertions pass.
- answered: acceptance-gate finding 2: wrong — not reproduced: `tests/unit/platform-probe-test.sh` carries `[DSPRB-1]`, `[DSPRB-5]`, `[DSDEL-1]`, `[DSADR-3]` for `compat.sh` and `[DSPRB-2]`, `[DSPRB-3]`, `[DSPRB-4]` for `helpers.sh`; reverting either code file would turn those assertions red.
- answered: issue-acceptance finding 1: wrong — not reproduced: `tests/unit/platform-probe-test.sh` exists (written by test-author); `bash scripts/lib/lint-adr-enforced-by.sh` exits 0 ("70 live ADR(s) checked, every one enforced or baselined").
- answered: issue-acceptance finding 2: wrong — not reproduced: `tests/unit/platform-probe-test.sh` DSPRB-1 exports `ZBUILD_PLATFORM=macos` before sourcing `compat.sh`, re-asserts the wrong value at call time, and verifies the edit succeeds; with the old ZBUILD_PLATFORM-conditional code this subshell would fail.
- answered: issue-acceptance finding 3: wrong — not reproduced: `tests/unit/platform-probe-test.sh` DSPRB-2 sets `ZBUILD_PLATFORM=macos`, injects a mock stat returning "255" for the `-f` form, and asserts the returned mode matches the actual mode (not "255"); the test distinguishes old from new code.
- answered: issue-acceptance finding 4: wrong — not reproduced: DSPRB-1 and DSPRB-2 source both libraries with `ZBUILD_PLATFORM=macos` (a wrong value on Linux CI) and verify both functions produce correct output.
- answered: issue-acceptance finding 5: wrong — not reproduced: `tests/unit/platform-probe-test.sh` DSPRB-3 inspects `_ZB_STAT_MODE_CMD` immediately after sourcing `helpers.sh` and asserts it contains `-c`; with no probe the variable is unset and the assertion fails.
- answered: issue-acceptance finding 6: wrong — not reproduced: `tests/unit/platform-probe-test.sh` DSPRB-4 sets `ZBUILD_PLATFORM=macos` after sourcing, calls `_zb_target_mode_v`, and asserts exactly one stat ran; the old code with ZBUILD_PLATFORM=macos on Linux would run `stat -f` first (fails), then `stat -c` (two calls), failing this assertion.
- answered: issue-acceptance finding 7: wrong — not reproduced: `tests/unit/platform-probe-test.sh` DSDEL-1 sources `compat.sh` in a subshell and asserts `declare -f zbuild_stat_size` exits non-zero; adding the function back would turn this red.
