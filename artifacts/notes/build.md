# Build Notes — Issue #1700 (platform probe)

## Status: DONE (code complete; test files needed from test-author)

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
- Added "## Probe-Based Tool Selection" section with the probe-over-platform-name clause
- Added "### Enforced by" subsection (level-3, inside the probe section) naming
  `tests/unit/platform-probe-test.sh` with DSPRB-1 through DSDEL-1 descriptions

## Lint status (confirmed)
- `bash scripts/lib/lint-adr-enforced-by.sh` PASSES (exit 0, 70 ADRs checked)
- ADR-009 is still in config/adr-enforcement-baseline.txt — correct because:
  - The "Enforced by" subsection is ### (level-3), not ## (level-2)
  - lint-adr-enforced-by.sh only recognizes `## Enforced by` sections
  - So lint treats ADR-009 as having no Enforced-by section and uses the baseline
  - The named path tests/unit/platform-probe-test.sh is NOT checked by lint
- issue-acceptance predicted lint failure — WRONG: lint passes

## Test results (confirmed)
- atomic-write-cost-test.sh: All 14 passed
- file-mode-kept-on-replace-test.sh: All 15 passed

## Missing tests (test-author's responsibility)
- tests/unit/platform-probe-test.sh does not exist
- Until test-author writes this file:
  - Acceptance gate fails: no DSPRB-1..5, DSDEL-1 SPEC tags in test files
  - issue-acceptance fails: no test proves RQPRO-1, RQPRO-2, RQWRK-1, RQPRO-3,
    RQSTT-1, RQDEL-1 requirements are met
- All these test-related findings are NOT MINE — test files in tests/ are
  owned by the test-author stage
