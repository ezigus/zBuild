# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 12 — COMPLETE (all acceptance tests pass)

## Summary of work done across all iterations

### Core implementation (complete)
1. **ADR-006 step 3.6** — Added ordering constraint phrase on a single line.
2. **ADR-050 §6** — Added boundary note (new run vs resume distinction) and updated Enforced by section.
3. **artifact-persist.sh** — Added `_artifact_persist_put_back` function (extracted from hydrate).
4. **hydrate/plugin.sh** — Redirect `hydrate_run` call site to `_artifact_persist_put_back`.
5. **runner.sh** — Added `_runner_resume_rehydrate`, `_runner_from_stage_preflight`, auto-resume via latest symlink (ENTR-2), security sanitization of run_id, readlink containment check, SRE warnings.
6. **cycle-orchestrator.sh** — `_start_iter` from persisted state on resume (ITER-1), CMBR-1 skip guard (uses `_is_resume` not `_start_iter>1` to cover iter=1 interruptions), removed erroneous `iter>0` unconditional stage.start guard (Gap 7 fix).

### Key bugs fixed in iteration 11-12
- **Bug 1 (Gap 7)**: `iter > 0` guard always true → unconditional stage.start for every cycle member in every run. REMOVED entirely. stage.start for cycle members only via CMBR-1 `resume_first_iter=true` path.
- **Bug 2 (CMBR-1 iter=1)**: `_start_iter > 1` condition failed for iter=1 interruptions. Fixed by using `_is_resume=true` condition instead.
- **Bug 3 (blob entry)**: CMBR-1 skip added persisted verdict/status to blob before `continue`.

### Test results (iteration 12)
All 5 acceptance tests PASS:
- resume-rehydrate-test.sh: 47/47 ✓
- from-stage-rehydrate-test.sh: 12/12 ✓
- resume-loop-state-test.sh: 10/10 ✓
- resume-entry-points-test.sh: 18/18 ✓
- hydrate-stage-test.sh: 25/25 ✓
- cycle-member-dispatch-events-test.sh: 24/24 ✓

Previous iteration's test failures (non-#1805):
- `run-timed-out-test.sh` (#1944): CI timing fluke — passes locally (elapsed 12s, well within 17s bound)
- `sigterm-aborts-pipeline-test.sh`: CI timeout flakiness — SIGTERM handling unchanged by this branch

Shape-floor golden files: CORRECT as-is (unchanged). The `iter>0` unconditional guard that would have changed cycle-member events was removed in commit 3a1c3b47.

## FSTG-1 analysis (critical for understanding)
from-stage-rehydrate-test.sh line 111 uses `--resume --from-stage cyc`.
With `--resume`, `_ZBUILD_RESUME_ACTIVE=true` is exported before dispatch loop.
When cycle orchestrator runs for `cyc`:
- `_ZBUILD_RESUME_ACTIVE=true` → `_is_resume=true`
- `_persisted_iter=0` (cycle hasn't run yet) → `_start_iter=1`
- `_ZBUILD_RESUME_ACTIVE=false` consumed
- In loop iter=1: `_is_resume=true` and `iter==_start_iter=1` → `_cid_resume_first_iter=true`
- In _cycle_iter_dispatch: `cycled` has status="pending" → NOT skipped → stage.start emitted → dispatch ✓

For fresh run (FRSH-1):
- No --resume → `_ZBUILD_RESUME_ACTIVE` never set → `_is_resume=false`
- `_cid_resume_first_iter=false` → no stage.start for cycle members ✓
