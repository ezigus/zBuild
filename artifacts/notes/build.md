# Build Notes — Issue #1700 (platform probe)

## Status: DONE

## What was done

### scripts/lib/compat.sh
- Deleted `zbuild_stat_size` (no callers anywhere)
- Added load-time sed probe: `sed --version >/dev/null 2>&1`
  - GNU: `_ZB_SED_INPLACE_ARGS=(-i)`, BSD: `_ZB_SED_INPLACE_ARGS=(-i '')`
- Rewrote `zbuild_sed_inplace` to use `${_ZB_SED_INPLACE_ARGS[@]}`

### scripts/lib/helpers.sh
- Added load-time stat probe: `stat -c '%a' /dev/null >/dev/null 2>&1`
  - GNU: `_ZB_STAT_MODE_CMD="-c"`, BSD: `_ZB_STAT_MODE_CMD="-f"`
  - GNU form tried first (RQPRO-3)
- Rewrote `_zb_target_mode_v` to call stat exactly once using `_ZB_STAT_MODE_CMD`

### docs/adr/ADR-009-platform-aware-modularity.md
- Added "Probe-Based Tool Selection" section with the probe-over-platform-name clause
- Added "Enforced by" subsection naming `tests/unit/platform-probe-test.sh`

## Test results
- atomic-write-cost-test.sh: All 14 passed (W1 stat count correct)
- file-mode-kept-on-replace-test.sh: All 15 passed

## Note on missing tests
- test-author stage passed but wrote 0 test files (confirmed by stage I/O artifact)
- Tests for DSPRB-1..5, DSDEL-1 do NOT exist in the repo
- The pipeline will need test-author to write platform-probe-test.sh
