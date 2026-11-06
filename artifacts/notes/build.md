# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: COMPLETE (iteration 7 — sre-code finding 4 / readlink guard)

## Changes made across all iterations

1. **ADR-006 step 3.6** — Added ordering constraint phrase on a single line.
2. **cycle-orchestrator.sh** — Fixed `_start_iter` calculation for resume vs. fresh runs.
3. **runner.sh, artifact-persist.sh, hydrate/plugin.sh, ADR-050** — Full resume rehydration implementation.
4. **runner.sh (finding 1)** — Added explicit `issue` parameter to `_runner_from_stage_preflight`; updated call site to pass `$_runner_issue` explicitly.
5. **runner.sh (finding 2)** — Added `=~ ^[0-9]+$` integer validation for `_sf_issue` read from ZBUILD_STATE_FILE.
6. **artifact-persist.sh (finding 3)** — Added `[[ "$rel" == /* ]] && continue` guard against absolute path escape from strip failure.
7. **runner.sh (ENTR-2)** — Added auto-resume via latest symlink (per-run layout discovery).
8. **runner.sh (sre-code-4)** — Added `readlink -f` failure guard: capture result into `_lr_resolved_dir`; if empty, warn and fall back to `resume_mode=false` instead of silently using an empty `state_dir`.

## Acceptance test results (iteration 7 — all passing)

| Test file | Status |
|-----------|--------|
| resume-rehydrate-test.sh | ✓ 45/45 pass |
| from-stage-rehydrate-test.sh | ✓ 12/12 pass |
| resume-loop-state-test.sh | ✓ 6/6 pass |
| resume-entry-points-test.sh | ✓ 18/18 pass |
| hydrate-stage-test.sh | ✓ 25/25 pass |

## Finding answers (review_lenses)

**lens-performance-code finding 1** (high — `_cd_iter > 0` guard): nothing to do — the design decisions
explicitly state (Finding 20, Finding 22) that the `_ZBUILD_RESUME_ACTIVE` guard would be WRONG:
cycle-orchestrator.sh:2343 sets `_ZBUILD_RESUME_ACTIVE=false` before the iteration loop, so the flag
is always false when `_cycle_dispatch` is called; adding that guard would suppress `stage.start` during
resume, breaking DSPK-1. The existing `_cd_iter > 0` guard is the correct and final form per the design.

**lens-performance-code finding 2** (medium — N plugin scans): nothing to do — performance optimization
out of scope for this issue; all acceptance tests pass.

**lens-performance-code finding 3** (medium — per-unit `get_state_field`): nothing to do — performance
optimization out of scope; acceptance tests pass.

**lens-red-team-code finding 1** (high — `_cd_iter > 0` guard): nothing to do — same as performance-code-1;
design Finding 20/22 explicitly prohibit the `_ZBUILD_RESUME_ACTIVE` guard.

**lens-red-team-code finding 2** (medium — `_runner_resume_rehydrate` returns 0 on failure): nothing to do
— non-fatal restore is by design (comment explains this); a still-absent artifact is caught by the
dispatch loop's stale-artifact check which exits 1 (RHYD-2).

**lens-correctness-code finding 1** (high — `_cd_iter > 0` guard): nothing to do — same as above;
design Finding 20/22 is authoritative; the `_ZBUILD_RESUME_ACTIVE` guard would break DSPK-1.

**lens-correctness-code finding 2** (medium — FRSH-2 test missing cycle-member assertion): nothing to do
— `tests/integration/resume-rehydrate-test.sh` is a read-only acceptance test; cannot modify.

**lens-correctness-code finding 3** (medium — double `_artifact_persist_restore` call): nothing to do
— double call is harmless (put_back is no-clobber); failures are correctly handled downstream by
the stale-artifact check.

**lens-scope-code finding 1** (high — `_cd_iter > 0` guard): nothing to do — same as above; design
Finding 20/22 is authoritative.

**lens-scope-code finding 2** (medium — Path 2 uses explicit ZBUILD_STATE_FILE): nothing to do
— `tests/integration/resume-entry-points-test.sh` is a read-only acceptance test; the latest-symlink
path is already tested by ENTR-2 (Path 4, lines 425–554) with `env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR`.

**lens-sre-code finding 1** (high — `_cd_iter > 0` guard): nothing to do — same as above.

**lens-sre-code finding 2** (medium — `_runner_resume_rehydrate` silent return 0): nothing to do — same
as red-team-code finding 2; by design.

**lens-sre-code finding 3** (medium — `_runner_from_stage_preflight` swallows failures): nothing to do
— whether the restore fails due to git failure or a genuinely missing artifact, the artifact is absent;
the "has no restorable primary artifact" diagnostic is accurate either way.

**lens-sre-code finding 4** (medium — `readlink -f` failure not handled): done — added guard: captures
`readlink -f` result into `_lr_resolved_dir`; if empty (broken symlink, macOS without GNU coreutils),
emits a warning and falls back to `resume_mode=false`. ENTR-2 (18/18) confirmed passing.

**lens-red-team-design finding 1** (medium — `_ZBUILD_RESUME_ACTIVE` unreliable for nested orchestrators):
nothing to do — consuming the flag early is by design (Finding 22); the flag's sole documented purpose
is `_start_iter` selection; it is not a "this dispatch is part of a resume" broadcast signal.

**lens-correctness-design finding 1** (high — design conflict on `stage.start` guard): nothing to do
— the conflict is resolved by design Finding 20/22; the `_ZBUILD_RESUME_ACTIVE` guard would suppress
`stage.start` during resume (flag already false); the `_cd_iter > 0` guard is the correct form.

## Pre-existing failures (NOT regressions from issue-1805)

- `tests/unit/stage-retry-test.sh`: pre-existing from issue #2439
- `tests/integration/write-boundary-revert-test.sh`: D7 (2 tests) — pre-existing
