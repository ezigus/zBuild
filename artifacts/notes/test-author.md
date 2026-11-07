# test-author notes — issue #1805 (round 43: fix two open review_lenses findings)

## Status: COMPLETE

## Round 43 changes

### lens-correctness-code finding 2 (fix: test) — DONE
In `tests/integration/resume-loop-state-test.sh`, the DSCMBR-1 iter=2 sub-case
was hand-crafting `stage_statuses.test = "in_progress"` — an impossible value
(the real code writes "aborted" when a stage is interrupted). Changed to
`stage_statuses.test = "aborted"` (the production data shape).

Motivation: the skip-guard check (`stage_statuses[$s] == "complete"`) is now
tested against the production data shape. The behavior is the same (test not skipped),
but using the real value means a guard that accidentally matched "in_progress" would
no longer pass on the wrong logic.

Previous test-author answer of "nothing to do" was incorrect — this finding
was marked "fix: test" and belongs to this stage.

### lens-scope-code finding 1 (fix: test) — DONE
In `tests/integration/from-stage-rehydrate-test.sh`, added S5 sub-case (tagged
[#1805/DSFSTG-1]) that runs `--from-stage cyc` WITHOUT `--resume`.

This exercises `_runner_from_stage_preflight` with `skip_restore=false` —
the branch that performs the git archive restore itself, rather than relying
on a prior resume rehydration. The existing S3 and S4 sub-cases both use
`--resume --from-stage` (skip_restore=true), leaving the alternative path
completely untested.

The S5 sub-case:
1. Creates a git repo with intake artifact on the git state branch
2. Removes the artifact from disk
3. Runs `--from-stage cyc --issue S5_ID` (no --resume)
4. Asserts: intake-result.json appears in ZBUILD_ARTIFACT_DIR (rehydrated)
5. Asserts: restored artifact contains the original payload
6. Asserts: no stage.start for intake

Failure logic (before the change):
- skip_restore=false path is absent or does not rehydrate → intake-result.json
  not on disk → assert_file_exists FAILS ✓
After the change:
- _runner_from_stage_preflight with skip_restore=false restores from git state
  branch → file present → PASSES ✓

Previous test-author answer of "not mine" was incorrect — this finding was
marked "fix: test" and belongs to this stage.

## Round 42 changes (from prior run)

### lens-scope-code finding 2 (fix: test) — DONE
Added write-side sub-section for [#1805/DSITER-1] in
`tests/integration/resume-loop-state-test.sh` (inserted between the
"without _ZBUILD_RESUME_ACTIVE" and DSCMBR-1 sections, ~line 197).

## Not mine (fix: code — cannot touch implementation)
lens-security-code findings 1-4
lens-red-team-code findings 1-3
lens-correctness-code finding 1
lens-performance-code finding 1
lens-sre-code findings 1-2

## All SPECs coverage (all confirmed on disk with correct tags)

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓, DSRHYD-2 ✓, DSAMDR-1 ✓, DSAMDR-2 ✓, DSDSPK-1 ✓
- DSFRSH-1 ✓, DSSKIP-1 ✓, DSFRSH-2 ✓, DSCYCL-1 ✓

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓ (with --resume S3 + without --resume S5), DSFSTG-2 ✓, DSCYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓ (read-side + write-side assertions), DSCMBR-1 ✓ (iter=2 and iter=1 scenarios), DSCYCL-1 ✓

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓, DSENTR-2 ✓, DSCYCL-1 ✓
