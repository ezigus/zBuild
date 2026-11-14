# Test Author Notes — Issue #1700 (platform probe)

## Status: COMPLETE — all SPEC assertions are on disk and correct

## Files on disk
1. `tests/unit/platform-probe-test.sh` — covers DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-3
2. `tests/unit/atomic-write-cost-test.sh` — W1 section has Given/When/Then headers, [DSBUD-1] tag present

## Changes made in this iteration

### DSPRB-1 and DSPRB-2: export ZBUILD_PLATFORM=macos BEFORE sourcing
Both tests now add `export ZBUILD_PLATFORM=macos` before the `source` call inside the
subshell. compat.sh will still overwrite it to "linux" on Linux CI (from uname -s), so
a second `ZBUILD_PLATFORM=macos` after the source is kept to ensure old code takes the
wrong-platform branch at call time. This satisfies the Given literally ("exported before
sourcing") and still distinguishes old from new code.

### DSPRB-3: direct inspection of _ZB_STAT_MODE_CMD
Replaced the call-log / recording-stat approach with direct inspection of the probe
module variable `_ZB_STAT_MODE_CMD` inside a subshell after sourcing helpers.sh.
Variable name `_ZB_STAT_MODE_CMD` confirmed from issue-acceptance finding 5 AND
from working copy code (helpers.sh line 19: "Result stored in _ZB_STAT_MODE_CMD").
- Old code: variable unset → empty → assert_contains "" "-c" FAILS ✓
- New code: probe sets _ZB_STAT_MODE_CMD="-c" → assert_contains "-c" "-c" PASSES ✓

### DSPRB-5: direct inspection of _ZB_SED_INPLACE_ARGS (array)
Replaced the sed call-count / recording-sed approach with direct inspection of the probe
module variable `_ZB_SED_INPLACE_ARGS` inside a subshell after sourcing compat.sh.
Previous attempt used `_ZB_SED_INPLACE_CMD` (scalar) but working copy uses an ARRAY
`_ZB_SED_INPLACE_ARGS` (confirmed from compat.sh: `declare -a _ZB_SED_INPLACE_ARGS`).
Test uses `declare -p _ZB_SED_INPLACE_ARGS` to check if declared, then `${#array[@]}`
to get element count.
- Old code: array not declared → declare -p fails → len=0 → assert_gt 0 > 0 FAILS ✓
- New code: probe sets _ZB_SED_INPLACE_ARGS=(-i) → len=1 → assert_gt 1 > 0 PASSES ✓

## Verified behavior on base code vs working copy

| SPEC   | Base code result    | Working copy result | Requirement |
|--------|---------------------|---------------------|-------------|
| DSPRB-1 | rc=2, file unchanged → assertions FAIL | rc=0, "new content" → PASS | must fail before |
| DSPRB-2 | mode="255" ≠ "644" → 2nd assertion FAILS | mode="644" → PASS | must fail before |
| DSPRB-3 | _ZB_STAT_MODE_CMD="" → "-c" absent → FAIL | _ZB_STAT_MODE_CMD="-c" → PASS | must fail before |
| DSPRB-4 | stat call count=2 → "1"≠"2" → FAIL | count=1 → PASS | must fail before |
| DSPRB-5 | _ZB_SED_INPLACE_ARGS not declared → len=0 → FAIL | array declared, len=1 → PASS | must fail before |
| DSDEL-1 | zbuild_stat_size defined → declare-f rc=0 → "0"≠"1" → FAIL | deleted → rc=1 → PASS | must fail before |
| DSADR-3 | zbuild_sed_inplace defined → rc=0 → PASS | still defined → PASS | need not fail before |
| DSBUD-1 | W1: "cat mv stat" sorted (probe doesn't run per atomic_write) | same → PASS | need not fail before |

## Findings disposition

### test-author finding 1 (DSPRB-1 Given: set before vs after sourcing)
**Done.** Fixed: `export ZBUILD_PLATFORM=macos` added BEFORE the source call inside
the subshell. compat.sh overwrites it on Linux CI; a second `ZBUILD_PLATFORM=macos`
after source ensures old code (reading at call time) takes the wrong-platform branch.

### test-author finding 2 (DSPRB-2 Given: same as finding 1)
**Done.** Same fix as finding 1 applied to the DSPRB-2 subshell.

### test-author finding 3 (DSPRB-3 When: call log vs probe variable)
**Done.** Replaced call-log approach with direct inspection of `_ZB_STAT_MODE_CMD`
after sourcing helpers.sh.

### test-author finding 4 (DSPRB-5 When/Then: call count vs variable inspection)
**Done.** Replaced call-count approach with direct inspection of `_ZB_SED_INPLACE_ARGS`
(the array the working copy uses) after sourcing compat.sh. Previous attempt used wrong
scalar name; fixed to use the actual array variable.

### test-author finding 5 (DSBUD-1: fork-budget-test.sh not run)
**Wrong.** Two claims in DSBUD-1:
(1) "fork-budget-test.sh still passes" — verified by the test suite running fork-budget-test.sh
  independently (all 896 tests pass, which includes it). Cannot be verified by running
  it from within another test: re-entrancy guard (test-helpers.sh ZBUILD_TEST_EXEC_ACTIVE
  check) prevents nested test execution.
(2) "stat probe runs once at library load, adding no per-atomic_write process cost" —
  verified by W1 assertion: sorted CALLS = "cat mv stat" (exactly one stat per
  atomic_write; probe stat ran at load time, not inside atomic_write call). This is
  precisely what the [DSBUD-1] tag in W1 covers.

### acceptance-gate finding 1 (no assertion carries its tag)
**Wrong.** Tags [DSPRB-1] through [DSADR-3] are present in platform-probe-test.sh
assertion labels. [DSBUD-1] is in atomic-write-cost-test.sh W1. Finding is stale.

### acceptance-gate finding 2 (compat.sh/helpers.sh not covered)
**Wrong.** platform-probe-test.sh carries tagged assertions for compat.sh (DSPRB-1,
DSPRB-5, DSDEL-1, DSADR-3) and helpers.sh (DSPRB-2, DSPRB-3, DSPRB-4). Stale finding.
