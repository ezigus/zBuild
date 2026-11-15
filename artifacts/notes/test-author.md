# Test Author Notes — Issue #1700 (platform probe)

## Status: COMPLETE — all SPEC assertions are on disk and correct

## Files on disk
1. `tests/unit/platform-probe-test.sh` — covers DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-3
2. `tests/unit/atomic-write-cost-test.sh` — W1 section has Given/When/Then headers, [DSBUD-1] tag present
3. `tests/e2e/fork-budget-test.sh` — [DSBUD-2] assertion at the end checking FAIL==0; Given/When/Then added to all SPEC blocks

## Findings addressed in this pass

### Finding 1 (DSPRB-1): Given/When placement
Fixed: `export ZBUILD_PLATFORM=macos` and `source compat.sh` moved to `# Given` section inside the subshell.
`# When` comment now appears only before the `zbuild_sed_inplace` call.

### Finding 2 (DSPRB-2): Given/When placement
Fixed: `# Given` comment covers `export ZBUILD_PLATFORM=macos` + `source helpers.sh`.
`# When` comment inside the subshell appears only before `_zb_target_mode_v` call.

### Finding 3 (DSPRB-4): Given/When placement
Fixed: `source helpers.sh` now under `# Given` inside the subshell.
`# When` comment appears before `_zb_target_mode_v _mode_out4 "$_f4"` only.

### Finding 4 (DSPRB-5): Given has no executable code
Fixed: `source compat.sh` now under `# Given` inside the `$( )` subshell.
`# When` comment appears before the `declare -p _ZB_SED_INPLACE_ARGS` inspection.

### Finding 5 (DSBUD-2): tag on wrong assertion + no Given/When/Then
Fixed:
- Removed `[DSBUD-2]` from SPEC-4 `assert_pass`/`assert_fail` lines (kept `[SPEC-4]`)
- Added Given/When/Then comments to all SPEC blocks in fork-budget-test.sh
- Added new DSBUD-2 block at the end (before cleanup_test_env):
  ```bash
  # Given — load-time probes in place
  # When — test runs (all SPECs above)
  # Then
  assert_eq "[DSBUD-2] tests/e2e/fork-budget-test.sh passes (exits 0) after the probe change" \
      "0" "$((FAIL > 0))"
  ```
  This checks `FAIL == 0` — every prior assertion passed — which is what "the test exits 0" means.

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
| DSBUD-2 | FAIL==0 at end → "0"=="0" → PASS on base code | still PASS | need not fail before |
