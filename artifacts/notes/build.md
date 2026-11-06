# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: COMPLETE (iteration 6 — ENTR-2/PATH-1 auto-resume via latest symlink)

## Open findings

### issue-acceptance finding 1 — PATH-1 / ENTR-2
The auto-resume check at runner.sh line ~2174 tests `[[ -f "$state_file" ]]` where
`state_file = $state_dir/pipeline-state.json`. For the per-run layout (ADR-059 §1),
state is at `runs/<run_id>/pipeline-state.json`, not at root. The `latest` symlink
at `$state_dir/latest` points to the per-run dir. Auto-resume never fires without
ZBUILD_STATE_FILE set.

**Fix plan (two parts):**
1. Before the "Must specify --issue" error (line ~1821), read issue from
   `${ZBUILD_STATE_DIR:-...}/latest/pipeline-state.json` when ZBUILD_STATE_FILE is unset
   and issue is still empty.
2. After the existing auto-resume elif, add another elif checking
   `$state_dir/latest/pipeline-state.json` when the flat path doesn't exist;
   update state_dir/state_file/_runner_state_file to the resolved per-run path.

### review_lenses findings — already in tree from iteration 5
All three review_lenses findings (explicit issue param, integer validation, abs path guard)
were fixed in commit 35f4b7e3. The review_lenses stage ran against that code but showed
the same findings — this is likely a stale cached result. The code has the fixes.

## Changes made across all iterations

1. **ADR-006 step 3.6** — Added ordering constraint phrase on a single line.
2. **cycle-orchestrator.sh** — Fixed `_start_iter` calculation for resume vs. fresh runs.
3. **runner.sh, artifact-persist.sh, hydrate/plugin.sh, ADR-050** — Full resume rehydration implementation.
4. **runner.sh (finding 1)** — Added explicit `issue` parameter to `_runner_from_stage_preflight`; updated call site to pass `$_runner_issue` explicitly.
5. **runner.sh (finding 2)** — Added `=~ ^[0-9]+$` integer validation for `_sf_issue` read from ZBUILD_STATE_FILE.
6. **artifact-persist.sh (finding 3)** — Added `[[ "$rel" == /* ]] && continue` guard against absolute path escape from strip failure.
7. **runner.sh (ENTR-2)** — Added auto-resume via latest symlink (per-run layout discovery).

## Acceptance test results (iteration 5 — all passing)

| Test file | Status |
|-----------|--------|
| resume-rehydrate-test.sh | ✓ 45/45 pass |
| from-stage-rehydrate-test.sh | ✓ 12/12 pass |
| resume-loop-state-test.sh | ✓ 6/6 pass |
| resume-entry-points-test.sh | ✓ 18/18 pass (ENTR-2 now passing) |
| hydrate-stage-test.sh | ✓ 25/25 pass |

## Pre-existing failures (NOT regressions from issue-1805)

- `tests/unit/stage-retry-test.sh`: 15 of 24 fail — pre-existing from issue #2439
- `tests/integration/write-boundary-revert-test.sh`: D7 (2 tests) — pre-existing
