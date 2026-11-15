## review-lens-correctness — fail

- found: medium: DSPRB-3 asserts `_ZB_STAT_MODE_CMD` contains `-c` unconditionally, but on a macOS host (where `stat -c '%a'` fails) the probe correctly sets the BSD `-f` form; the test has no host guard and would produce a false failure on BSD. (tests/unit/platform-probe-test.sh) (and 2 more)

- medium: DSPRB-3 asserts `_ZB_STAT_MODE_CMD` contains `-c` unconditionally, but on a macOS host (where `stat -c '%a'` fails) the probe correctly sets the BSD `-f` form; the test has no host guard and would produce a false failure on BSD. (tests/unit/platform-probe-test.sh)
- medium: `_actual_mode` is computed unconditionally with `stat -c '%a'`; on a macOS host where BSD stat ignores `-c`, `_actual_mode` is silently empty, making the subsequent `assert_eq` compare empty string to `_dsprb2_mode` and fail even when the implementation is correct on BSD. (tests/unit/platform-probe-test.sh)
- medium: The DSBUD-2 assertion checks whether `FAIL > 0` is `0` at that point in the script, which is tautological — it passes whenever every prior assertion passed, adding no independent verification that the probe specifically avoids extra `stat` processes in the fork budget. (tests/e2e/fork-budget-test.sh)
- score: 7
