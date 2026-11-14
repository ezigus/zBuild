## test-author — unusable

- changed 2 test file(s); 5 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/unit/platform-probe-test.sh — DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-3
- tests/unit/atomic-write-cost-test.sh — DSBUD-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: acceptance-gate finding 1: done — wrote `tests/unit/platform-probe-test.sh` with [DSPRB-1], [DSPRB-2], [DSPRB-3], [DSPRB-4], [DSPRB-5], [DSDEL-1], [DSADR-3] tags in assertion labels; added [DSBUD-1] to `tests/unit/atomic-write-cost-test.sh` W1 assertion.
- answered: acceptance-gate finding 2: done — `tests/unit/platform-probe-test.sh` now carries tagged assertions for `scripts/lib/compat.sh` and `scripts/lib/helpers.sh` behavior; reverting either file would turn DSPRB-1 through DSPRB-5, DSDEL-1 red.
- answered: issue-acceptance finding 1: done — `tests/unit/platform-probe-test.sh` exists on disk; it is the file ADR-009's Enforced-by section references.
- answered: issue-acceptance finding 2: done — DSPRB-1 sets ZBUILD_PLATFORM=macos and verifies `zbuild_sed_inplace` edits the file; on base code (platform branch) the sed call errors and the assertion fails.
- answered: issue-acceptance finding 3: done — DSPRB-2 sets ZBUILD_PLATFORM=macos and verifies `_zb_target_mode_v` returns the actual mode (not "255" from the mock BSD branch); on base code the assertion fails.
- answered: issue-acceptance finding 4: done — both DSPRB-1 and DSPRB-2 set ZBUILD_PLATFORM=macos (wrong for Linux CI) and verify correct output; that covers RQWRK-1.
- answered: issue-acceptance finding 5: done — DSPRB-3 intercepts stat during source of helpers.sh, reads the first call log entry, and asserts it contains "-c"; on base code there are no load-time stat calls so the assertion fails.
- answered: issue-acceptance finding 6: done — DSPRB-4 uses ZBUILD_PLATFORM=macos (Linux with base code triggers stat -f first → fails → fallback = 2 calls); new code uses probe → 1 call. The W1 assertion in atomic-write-cost-test.sh covers Linux CI but DSPRB-4 specifically covers the ZBUILD_PLATFORM=macos scenario that exposed the second stat.
- answered: issue-acceptance finding 7: done — DSDEL-1 sources compat.sh and asserts `declare -f zbuild_stat_size` exits 1; on base code the function is defined so the assertion fails.
