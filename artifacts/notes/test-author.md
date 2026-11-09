# test-author notes — issue #1805 (round 55)

## Status: COMPLETE

All 17 SPECs confirmed on disk with correct tags.

## Round 55 — fixed DSFSTG-3 fixture-not-found crash on before-code

**Problem**: test-author finding 1: DSFSTG-3 test stopped early (before DSFSTG-3
assertions ran) because `install_template_overlay "$S10_WORK_REPO" from-stage-combined-resume`
failed on the before-code state — the fixture `from-stage-combined-resume.yaml` was added
by this iteration and doesn't exist in the before-code worktree. With `set -euo pipefail`
active, the error exited the script before DSFSTG-3 assertions could run.

**Fix**: In `tests/integration/from-stage-rehydrate-test.sh` lines 636-642, changed
the direct `install_template_overlay` call to a guarded form:

```bash
_s10_tpl_rc=0
install_template_overlay "$S10_WORK_REPO" from-stage-combined-resume 2>/dev/null \
    || _s10_tpl_rc=$?
```

With this guard, on before-code:
- `install_template_overlay` fails (fixture absent) → `_s10_tpl_rc=1`
- Script continues
- Runner is invoked but `--template from-stage-combined-resume` can't be loaded → exits non-zero
- Events file: not created
- `_s10_cyc_starts=0` → `assert_gt 0 0` → FAILS ✓ (tagged [#1805/DSFSTG-3])
- `_s10_verify_starts=0` → `assert_gt 0 0` → FAILS ✓ (tagged [#1805/DSFSTG-3])

This satisfies both acceptance-gate findings:
1. DSFSTG-3 assertions ARE in the file (lines 718, 732, 743)
2. DSFSTG-3 assertions DO fail on before-code (not short-circuited by fixture error)

## Round 54 — added DSFSTG-3

The DSFSTG-3 test section and `from-stage-combined-resume.yaml` fixture were added.
The fixture is a 3-unit pipeline: [intake (leaf), cyc (cycle with cycled), verify (leaf)].

## Open findings

- **issue-acceptance finding 1**: pipeline-resume-test.sh stale assertions → NOT MINE
  (file not in my named testfiles — the named testfiles are the 5 listed in the contract)

## All SPECs coverage

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓, DSRHYD-2 ✓, DSAMDR-1 ✓, DSAMDR-2 ✓, DSDSPK-1 ✓
- DSFRSH-1 ✓, DSSKIP-1 ✓, DSFRSH-2 ✓, DSCYCL-1 ✓

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓, DSFSTG-2 ✓, DSFSTG-3 ✓, DSCYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓, DSCMBR-1 ✓, DSCYCL-1 ✓

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓, DSENTR-2 ✓, DSCYCL-1 ✓
