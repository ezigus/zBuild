# test-author notes — issue #1805 (round 60)

## Status: DSFSTG-4 SYMLINK SUB-CASE ADDED

Added S12 sub-case to tests/integration/from-stage-rehydrate-test.sh to cover the
`latest`-symlink auto-resume path for DSFSTG-4 (the gap identified in issue-acceptance
finding 1).

## What was done

The existing S11 sub-case of DSFSTG-4 sets `ZBUILD_STATE_FILE` explicitly (flat-file
path). The issue-acceptance finding said the NEW branch code's guard fires only when
the flat state file exists; when state is under a per-run dir found via the `latest`
symlink (the DSENTR-2 auto-resume path), the guard is skipped.

Added S12 sub-case that:
- Creates state at `$ZBUILD_STATE_ROOT/runs/<run_id>/pipeline-state.json` with
  `status=interrupted`
- Creates `$ZBUILD_STATE_ROOT/latest` symlink pointing to the per-run dir
- Invokes runner with `env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR` so the symlink
  guard can activate
- Asserts: exit 1, stderr contains "--from-stage is only valid with --resume", no
  `pipeline.resume` event

This test FAILS on the current branch code (guard doesn't fire for symlink path) and
passes after the guard is extended to cover the symlink path.

## All SPECs coverage

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓, DSRHYD-2 ✓, DSAMDR-1 ✓, DSAMDR-2 ✓, DSDSPK-1 ✓
- DSFRSH-1 ✓, DSSKIP-1 ✓, DSFRSH-2 ✓, DSCYCL-1 ✓

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓, DSFSTG-2 ✓, DSFSTG-3 ✓, DSFSTG-4 ✓ (S11 flat-file + S12 symlink-path), DSCYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓, DSCMBR-1 ✓, DSCYCL-1 ✓

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓, DSENTR-2 ✓, DSCYCL-1 ✓

### tests/unit/descriptive-id-readers-test.sh
- DSFSTG-1 ✓

## Findings answered

### issue-acceptance finding 1
Done. Added S12 sub-case to from-stage-rehydrate-test.sh covering the `latest`-symlink
auto-resume path. The test asserts exit 1 and "--from-stage is only valid with --resume"
diagnostic even when ZBUILD_STATE_FILE is unset and state is found via the latest symlink.

### lens-correctness-code finding 2
Wrong. `"aborted"` is the status the engine writes for an interrupted cycle member.
Confirmed in `core/pipeline/cycle-orchestrator.sh` base code. DSCMBR-1 tests the
interrupted-member case; "all complete" is a different scenario beyond the stated
requirements.

### lens-correctness-design finding 1
Not mine. This is about the implementation in `core/pipeline/runner.sh`. The DSFSTG-3
test correctly asserts the observable behavior.
