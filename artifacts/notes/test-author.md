# test-author notes — issue #1805 (round 23: DLGT-1 Given/When/Then fix)

## Status: COMPLETE — all findings addressed

## Changes made this round

### tests/unit/hydrate-stage-test.sh
Added `# Given`, `# When`, `# Then` section heading comments to the
`[#1805/DLGT-1]` test section.

The open finding from the previous test-author stage was:
> DLGT-1[code]: no Given, When, or Then heading comment appears inside the
> DLGT-1 test section; the block comment above the `print_test_section` line
> describes the mechanism but is not a per-part heading.

Fix: added the three section headings in the correct positions:
- `# Given` — before the sentinel function definition and state setup
- `# When` — before the `hydrate_run` call (the single action)
- `# Then` — before `assert_file_exists`

## All SPECs and their test files

### tests/unit/hydrate-stage-test.sh
- DLGT-1: sentinel test with Given/When/Then headings; overrides
  _artifact_persist_put_back with touch, calls hydrate_run, asserts sentinel written.

### tests/integration/resume-rehydrate-test.sh
- RHYD-1: 3 paths (--resume, auto-resume/interrupted, zbuild pipeline resume),
  each with Given/When/Then sections; artifact-present, byte-identical, pipeline.resume
  before stage.start, no intake.stage.start
- RHYD-2: exit 1 when artifact absent; no stage.start before exit
- AMDR-1: ADR-006 contains 3.6, _runner_resume_rehydrate, resume-rehydrate-test.sh,
  resume-entry-points-test.sh, "exit 1", "before the dispatch loop", "git state branch",
  "not to be combined with dispatch-loop changes"
- AMDR-2: ADR-050 s6 contains "new run", "ADR-006", "continues the same run"
- DSPK-1: stage k (cyc → member cycled) dispatched and emits stage.start on resume
- FRSH-1: (1) intake dispatched from stage 1, (2) no stage.skip events,
  (3) prior-run artifact content NOT in ZBUILD_ARTIFACT_DIR
- CYCL-1: fixture has type:cycle; pipeline was run

### tests/integration/from-stage-rehydrate-test.sh
- FSTG-1: artifact-present, content from git state, pipeline.resume before dispatch,
  intake emits no stage.start, stage.start for cycled (inner member of cyc)
- FSTG-2: exit 1; stderr contains "has no restorable primary artifact"; no stage.start
- CYCL-1: fixture has type:cycle

### tests/integration/resume-loop-state-test.sh (unchanged)
- ITER-1 clause 1: first dispatched iter is 2 (with _ZBUILD_RESUME_ACTIVE=true + current_iter=2)
- ITER-1 clause 2: iter-1 stages not dispatched on resume into iter-2
- ITER-1 clause 2b: nested-loop re-entry after outer resume starts at iter=1
- ITER-1 clause 3 (guard): without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1

### tests/integration/resume-entry-points-test.sh (unchanged)
- ENTR-1 for all 3 paths: artifact restored, pipeline.resume emitted, pipeline.resume
  precedes first stage.start, NO stage.start for intake (complete stage skipped)

## Findings answered

ANSWER test-author finding 1: done — added `# Given`, `# When`, `# Then` section headings
  to the [#1805/DLGT-1] block in tests/unit/hydrate-stage-test.sh
