# test-author notes — issue #1805

## Status: writing remaining test files

## Files to write (4 total)

1. `tests/integration/resume-rehydrate-test.sh` — SPEC-1, SPEC-2, SPEC-5, SPEC-6 ✅ DONE
2. `tests/integration/from-stage-rehydrate-test.sh` — SPEC-3, SPEC-4 ← in progress
3. `tests/integration/resume-loop-state-test.sh` — SPEC-7
4. `tests/integration/resume-entry-points-test.sh` — SPEC-9

## Key facts discovered

### Codebase

- `_artifact_persist_restore <issue> <restored_dir> [repo_root]` — extracts state branch into
  `restored_dir`. Requires CWD or explicit repo_root to be a git repo.
- `_artifact_persist_put_back <from> <to>` — NEW function (NOT yet in code).
  Copies files from `from/` to `to/`, skipping stage-io/ and existing files.
- `_runner_resume_rehydrate` — NEW function. NOT YET IN CODE. Called at runner.sh resume entry.
- `_runner_from_stage_preflight` — NEW function. NOT YET IN CODE.

### Before the change (what makes tests FAIL)

- SPEC-1: runner.sh resume entry does NOT call restore/put_back → artifact missing → fails
- SPEC-2: stale-artifact check warns+continues → exits 0 → fails
- SPEC-3: --from-stage path has no restore/put_back → artifact missing → fails
- SPEC-4: no artifact check in from-stage path → exits 0 (or non-1) → fails
- SPEC-7: cycle always starts from iter=1 → first dispatch is iter=1 → fails
- SPEC-9: no rehydration in any path → artifact absent → fails

### Test setup pattern for artifact rehydration

1. `WORK_REPO="$(setup_git_temp_repo name)"` — git repo (already has user.email/name set)
2. `install_template_overlay "$WORK_REPO" runner-state-dir-minimal`
3. `source "$REPO_ROOT/core/state/artifact-persist.sh"`
4. Create `$state_dir/artifacts/intake-result.json`
5. `( export ZBUILD_STATE_DIR="$state_dir"; cd "$WORK_REPO" && _artifact_persist_snapshot "$state_dir" "$_ZB_ID" )`
6. Remove artifact from disk
7. Write state file: `{stage_statuses: {intake: "complete", build: "pending"}, status: "in_progress"}`
8. Run runner subprocess with CWD=$WORK_REPO

### SPEC-3: --from-stage rehydration

- Same snapshot setup as SPEC-1 but run with `--from-stage build`
- Assert intake artifact exists in state_dir/artifacts
- Assert no stage.start for "intake" in events.jsonl

### SPEC-4: --from-stage with missing artifact

- NO snapshot — fresh work_repo for new issue ID
- Run with `--from-stage build`
- Assert exit code 1
- Assert stderr contains "intake" (names the missing stage)
- Assert no stage.start events

### SPEC-7: cycle orchestrator reads current_iter from state on resume

- `zb_engine_loop_state` with rounds=1 → current_iter=1 (iter 1 complete)
- After fix: orchestrator starts from current_iter+1 = iter 2
- Before fix: always starts from iter=1
- Assert first dispatched iter == 2
- FAILS before (first=1), PASSES after (first=2)

The discriminating assertion: first_dispatched_iter == 2.

Mock setup (from core-pipeline-cycle-orchestrator-test.sh pattern):
```bash
_SPEC7_FIRST_ITER=-1
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    [[ "$_SPEC7_FIRST_ITER" -eq -1 ]] && _SPEC7_FIRST_ITER="$iter"
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}
```

Note: also need `source "$REPO_ROOT/tests/lib/cycle-report-stub.sh"` and
`zb_stub_reports_tests test` (from cycle-orchestrator-test.sh pattern).

### SPEC-9: three entry paths all invoke rehydration

Path 1: `bash "$RUNNER" --resume --template ... --issue N` → resume_mode=true
Path 2: `bash "$RUNNER" --template ... --issue N` with state status=interrupted → auto_resume → resume_mode=true
Path 3: `bash "$ZBUILD_SCRIPT" pipeline resume --run-id RID` → calls runner with --resume

Each: setup work_repo + snapshot + state file, run via specific path, assert artifact present.

For path 3:
- ZBUILD_STATE_DIR must be set and state file at $state_dir/pipeline-state.json
- run_id stored in state as "s9-p3-resume-1805"
- zbuild changes status to in_progress before calling runner

### Important env vars for runner subprocess

- ZBUILD_CYCLES_ENABLED=0
- ZBUILD_PLUGINS_ROOT (from mock_plugin_factory output)
- ZBUILD_STATE_DIR, ZBUILD_STATE_FILE
- ZBUILD_EVENTS_DIR, ZBUILD_EVENTS_JSONL
- ZBUILD_EVENT_SCHEMA
- ZBUILD_CONTRACT_VALIDATOR=warn
- ZBUILD_VISION_GATE=off
- PATH, HOME

### locked_state_update

Needed by cycle-orchestrator.sh; sourced from core/state/atomic.sh which
cycle-orchestrator.sh sources automatically.

### _find_state_file for zbuild pipeline resume

Scans `$state_dir/runs/*/pipeline-state*.json` and `$state_dir/pipeline-state*.json`.
Simplest: place state file at `$state_dir/pipeline-state.json`.

## Progress

- [x] Notes written
- [x] resume-rehydrate-test.sh (SPEC-1, SPEC-2, SPEC-5, SPEC-6)
- [ ] from-stage-rehydrate-test.sh (SPEC-3, SPEC-4) ← writing now
- [ ] resume-loop-state-test.sh (SPEC-7)
- [ ] resume-entry-points-test.sh (SPEC-9)
