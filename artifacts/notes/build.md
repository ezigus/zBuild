# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 11 — fixing review_lenses findings

## Critical bugs to fix this iteration

### Bug 1: `iter > 0` guard always true (cycle-orchestrator.sh:1866)
The guard `if [[ "$iter" -gt 0 ]]; then eb_emit_event "stage.start"...` is ALWAYS true
since iter starts at _start_iter ≥ 1. This unconditionally emits stage.start for EVERY
cycle member in EVERY run (fresh + resume), violating GUAR-1.

**Acceptance test failure:** resume-rehydrate-test.sh line 800:
  `assert_eq "[#1805/FRSH-1] no stage.start for cycle member (cycled) on fresh run" "0" "$_s12_cycled_starts"`

**Fix:** 
- Remove the `iter > 0` block entirely
- In the CMBR-1 path: when `_resume_first_iter == "true"` AND member is NOT complete,
  emit stage.start for that member BEFORE dispatch.

This correctly handles FSTG-1 (--from-stage cyc --resume): `_ZBUILD_RESUME_ACTIVE=true`
→ `_is_resume=true` → `_cid_resume_first_iter=true` for iter=1 → cycled is not complete
→ stage.start emitted for cycled. ✓

### Bug 2: CMBR-1 `_start_iter > 1` condition (cycle-orchestrator.sh:2436)
When a run is interrupted during iter=1, `_persisted_iter=1` → `_start_iter=1`.
The condition `_start_iter > 1` is FALSE → `_cid_resume_first_iter=false` → 
complete iter-1 members are re-dispatched instead of being skipped.

**Acceptance test failure:** resume-loop-state-test.sh line 333:
  `assert_eq "[#1805/CMBR-1] no stage.start for 'build' in iter 1" "0" "$_CMBR1I1_BUILD_DISPATCHED"`

**Fix:**
- Add `local _is_resume=false` after `local _start_iter` in `_cycle_orchestrator_run_body`
- Set `_is_resume=true` when `_ZBUILD_RESUME_ACTIVE` was true (before consuming it)
- Change condition from `_start_iter > 1` to `_is_resume == "true"` (remove `_start_iter > 1`)

### Bug 3: CMBR-1 missing blob entry (cycle-orchestrator.sh:1446)
When CMBR-1 skips a complete member with bare `continue`, the predicate blob
doesn't have that member's entry. Fix: read persisted verdict from state file and
add entry to blob before `continue`.

## Security fixes

### Security 1: `_runner_run_id` not sanitized (runner.sh:2227)
In the latest-symlink auto-resume path, `_runner_run_id` is read from state file without
sanitization. Fresh-run path sanitizes it (line 2246). Add same sanitization here.

### Security 2: readlink -f not validated against state root (runner.sh:2223)
Save original `state_dir` before updating; check that `_lr_resolved_dir` starts
with `${_lr_original_state_dir}/` to prevent symlink escape.

## SRE fixes (medium severity)
- `_runner_resume_rehydrate`: add `warn` on `_artifact_persist_restore` failure before return 0
- `_runner_from_stage_preflight`: add `warn` on restore/put_back failures

## FSTG-1 analysis (critical for understanding)
from-stage-rehydrate-test.sh line 111 uses `--resume --from-stage cyc`.
With `--resume`, `_ZBUILD_RESUME_ACTIVE=true` is exported before dispatch loop.
When cycle orchestrator runs for `cyc`:
- `_ZBUILD_RESUME_ACTIVE=true` → `_is_resume=true`
- `_persisted_iter=0` (cycle hasn't run yet) → `_start_iter=1`
- `_ZBUILD_RESUME_ACTIVE=false` consumed
- In loop iter=1: `_is_resume=true` and `iter==_start_iter=1` → `_cid_resume_first_iter=true`
- In _cycle_iter_dispatch: `cycled` has status="pending" → NOT skipped → stage.start emitted → dispatch

This satisfies FSTG-1 assertion at line 185 (`cycled` stage.start count > 0). ✓

For fresh run (FRSH-1):
- No --resume → `_ZBUILD_RESUME_ACTIVE` never set → `_is_resume=false`
- `_cid_resume_first_iter=false` → no stage.start for cycle members ✓

## Changes made across all iterations

1. **ADR-006 step 3.6** — Added ordering constraint phrase on a single line.
2. **cycle-orchestrator.sh** — Fixed `_start_iter` calculation for resume vs. fresh runs.
3. **runner.sh, artifact-persist.sh, hydrate/plugin.sh, ADR-050** — Full resume rehydration implementation.
4. **runner.sh (finding 1)** — Added explicit `issue` parameter to `_runner_from_stage_preflight`; updated call site to pass `$_runner_issue` explicitly.
5. **runner.sh (finding 2)** — Added `=~ ^[0-9]+$` integer validation for `_sf_issue` read from ZBUILD_STATE_FILE.
6. **artifact-persist.sh (finding 3)** — Added `[[ "$rel" == /* ]] && continue` guard against absolute path escape from strip failure.
7. **runner.sh (ENTR-2)** — Added auto-resume via latest symlink (per-run layout discovery).
8. **runner.sh (sre-code-4)** — Added `readlink -f` failure guard: capture result into `_lr_resolved_dir`; if empty, warn and fall back to `resume_mode=false`.
9. **cycle-orchestrator.sh (CMBR-1 iteration 8)** — Added `_resume_first_iter` parameter to `_cycle_iter_dispatch`; call site passes `true` only for `iter == _start_iter && _start_iter > 1`; skip guard checks `stage_statuses[$s]` and continues if "complete".
10. **[iteration 10] cycle-orchestrator.sh + runner.sh** — Move stage.start emission for leaf cycle members into the orchestrator (before cycle_dispatch_stage call, after CMBR-1 skip guard); remove from runner.sh's cycle_dispatch_stage.
11. **[iteration 11] cycle-orchestrator.sh** — Fix _is_resume logic, remove iter>0 guard, move stage.start to CMBR-1 non-complete path, add blob update. **runner.sh** — sanitize run_id, add readlink containment check, add SRE warnings.
