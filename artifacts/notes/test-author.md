# test-author notes — issue #1805 (round 31: fixing ENTR-2 missing assert_gt)

## Status: COMPLETE

## Round 31: Fixed ENTR-2 missing assert_gt ordering comparison

**test-author finding 1 (was open, now fixed):**

The ENTR-2 section in `resume-entry-points-test.sh` was missing the `assert_gt`
comparison between `pipeline.resume` line number and first `stage.start` line number.
Paths 1-3 (ENTR-1) all had this check; ENTR-2 (path 4) only asserted
`pipeline.resume > 0` but never asserted `first_start > resume`.

The requirement says: "Completed-stage artifacts are restored from the per-run state
directory before any stage.start event is emitted." Without the lineno comparison,
a test where the artifact was placed AFTER a stage.start event would still pass the
existing assertions (artifact present + no intake stage.start).

**Fix applied:**
Added after the existing `assert_gt resume_lineno > 0` in the ENTR-2 (path 4) section:
1. Capture `_p4_first_start_lineno` via `awk '/"stage.start"/{print NR; exit}'`
2. `assert_gt "[#1805/ENTR-2] auto-resume via latest symlink: pipeline.resume precedes
   first stage.start (artifact restored before dispatch loop)" "$_p4_first_start_lineno"
   "$_p4_resume_lineno"`

Before-change failure: auto-resume not triggered → no pipeline.resume → resume_lineno=0
→ the first assert_gt (resume > 0) fails first. This new assertion adds explicit ordering
evidence ON TOP of the resume-fired evidence.

**Previous test-author's misattribution:** The round-30 answer said "done" but applied
the wrong fix (changed `_setup_path_state` for ENTR-1 state layout). The actual finding
(missing lineno comparison for ENTR-2) was not fixed in that round.

## Findings answered

ANSWER test-author finding 1: done — added `_p4_first_start_lineno` capture and
  `assert_gt "[#1805/ENTR-2] auto-resume via latest symlink: pipeline.resume precedes
  first stage.start"` to the ENTR-2 section of `resume-entry-points-test.sh`. This
  directly addresses "there is no assertion comparing the pipeline.resume line number
  against the first stage.start line number."

ANSWER issue-acceptance finding 1: nothing to do (test-author scope) — ENTR-1 state
  IS at `runs/<run_id>/` for all three paths (round-30 fix via `_setup_path_state`).
  The runner IS reading from `runs/<run_id>/pipeline-state.json` via ZBUILD_STATE_FILE/
  ZBUILD_STATE_DIR pointing there. ENTR-2 specifically tests auto-resume state discovery
  via `latest` symlink WITHOUT ZBUILD_STATE_FILE set — this is the discriminating test
  for the "runner finds state in runs/<run_id>/" sub-requirement for the auto-resume path.
  For paths 1 (--resume + explicit state file) and 3 (zbuild pipeline resume --run-id),
  explicitly providing the state file path is the correct usage model for those entry
  points. The code-level concern raised in the finding (runner doesn't scan runs/<run_id>/
  for auto-resume) is a code correctness matter, not a test matter. ENTR-2 would fail on
  code that cannot find state via latest symlink.

## All SPECs and their test files (complete coverage)

### tests/unit/hydrate-stage-test.sh
- DLGT-1: sentinel written by `_artifact_persist_put_back` override → hydrate_run called it

### tests/integration/resume-rehydrate-test.sh
- RHYD-1 (3 paths): artifact-present, byte-identical, pipeline.resume before stage.start,
  no intake.stage.start
- RHYD-2: exit 1 when artifact absent; no stage.start before exit
- AMDR-1: ADR-006 contains step 3.6, _runner_resume_rehydrate, test names, exit 1 clause,
  before the dispatch loop, git state branch, ordering constraint
- AMDR-2: ADR-050 §6 contains new run, ADR-006, continues the same run, test file citations
- DSPK-1: stage k (cyc → member cycled) dispatched and emits stage.start on resume
- FRSH-1: intake dispatched from stage 1; no stage.skip; no prior-run artifact in dir
- SKIP-1: dispatch-unit loop emits no stage.start for complete stage with artifact present
- FRSH-2: fresh run (no --resume, in_progress status) dispatches intake AND emits no stage.skip
- CYCL-1: fixture has type:cycle; pipeline was run

### tests/integration/from-stage-rehydrate-test.sh
- FSTG-1: artifact-present, content from git state, pipeline.resume before dispatch,
  intake emits no stage.start, stage.start for cycled
- FSTG-2: exit 1; stderr contains "has no restorable primary artifact"; no stage.start
- CYCL-1: fixture has type:cycle

### tests/integration/resume-loop-state-test.sh
- ITER-1 clause 1: first dispatched iter is 2 (with _ZBUILD_RESUME_ACTIVE=true + current_iter=2)
- ITER-1 clause 2: iter-1 stages not dispatched on resume into iter-2
- ITER-1 clause 2b: nested-loop re-entry starts at iter=1
- ITER-1 clause 3 (guard): without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1

### tests/integration/resume-entry-points-test.sh
- ENTR-1 for all 3 paths: state at runs/<run_id>/ per Given; artifact restored,
  pipeline.resume emitted, pipeline.resume precedes first stage.start,
  NO stage.start for intake — using artifact-snapshot-coverage (cyclic fixture)
- ENTR-2 (path 4): auto-resume via latest symlink — no ZBUILD_STATE_FILE set;
  state at $ZBUILD_STATE_ROOT/runs/<run_id>/ found via $ZBUILD_STATE_ROOT/latest;
  pipeline.resume emitted AND precedes first stage.start [FIXED THIS ROUND],
  artifacts restored, no stage.start for intake
