# Build Notes — Issue #1700 (platform probe)

## Status: COMPLETE — all tests pass, all SPEC tags present

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
- Added "## Probe-Based Tool Selection" section with probe-over-platform-name clause
- Added "### Enforced by" subsection naming `tests/unit/platform-probe-test.sh`
  with DSPRB-1 through DSDEL-1 descriptions

### tests/unit/platform-probe-test.sh (written by test-author stage)
- Covers DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-3
- All 9 assertions pass

### tests/unit/atomic-write-cost-test.sh (updated by test-author stage)
- Added [DSBUD-1] tag to W1 assertion (line 48: "[W1][DSBUD-1] it starts...")
- All 14 assertions pass

## Verified current state (this iteration)
- `bash tests/unit/platform-probe-test.sh`: All 9 passed
- `bash tests/unit/atomic-write-cost-test.sh`: All 14 passed
- `bash scripts/lib/lint-adr-enforced-by.sh`: 70 ADRs checked, every one enforced or baselined
- All SPEC tags present: [DSPRB-1]-[DSADR-3] in platform-probe-test.sh;
  [DSBUD-1] in atomic-write-cost-test.sh (embedded in "[W1][DSBUD-1]")
- git diff HEAD: no uncommitted changes (HEAD is test-author's last commit)

## Findings from previous run — all false (not reproduced)
The previous acceptance-gate and issue-acceptance findings were raised when
tests/unit/platform-probe-test.sh did not yet have SPEC-tagged assertions.
The test-author stage's last 3 commits ("test-author: acceptance assertions for
8 SPEC(s), still failing their check") added all required tags. Running
the test files now shows all assertions pass and all SPEC tags are present.
The findings do not reproduce on the current tree.
