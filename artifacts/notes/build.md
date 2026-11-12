# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 31 — All acceptance tests pass, no code changes needed

## Verification results (this iteration)

All 6 acceptance test files pass:
- tests/integration/resume-rehydrate-test.sh — 51 tests ✓
- tests/unit/hydrate-stage-test.sh — 25 tests ✓
- tests/unit/descriptive-id-readers-test.sh — 29 tests ✓
- tests/integration/from-stage-rehydrate-test.sh — 35 tests ✓
- tests/integration/resume-loop-state-test.sh — 11 tests ✓
- tests/integration/resume-entry-points-test.sh — 18 tests ✓

## This iteration's change: none (all findings answered, no code changes)

## Open findings — answers

### issue-acceptance finding 1 (RQFROM-4 regression for in_progress):
**wrong — the test is wrong**: tests/integration/from-stage-rehydrate-test.sh
The S5 sub-test (tagged [#1805/DSFSTG-1], lines 221-318) runs `--from-stage cyc`
WITHOUT `--resume` on `status=in_progress` and asserts SUCCESS. The same file
contains DSFSTG-4 tests (S11, S12) that run `--from-stage` without `--resume` on
`status=interrupted` and assert FAILURE. Satisfying both requires the narrowed guard
(fires only for `interrupted`). Broadening the guard to also catch `in_progress`
(which would fully satisfy RQFROM-4) causes S5 to fail. The two tests in the same
acceptance file are mutually incompatible with RQFROM-4 in full: S5 must be changed
to either use `--resume` or use a status that does not trigger auto-resume.

### issue-acceptance finding 2 (run-status-text.sh unasked change):
**wrong** — `tests/unit/descriptive-id-readers-test.sh` is in the acceptance test list
and asserts the backtick-pair rendering. Reverting `run-status-text.sh` would break
that acceptance test. The acceptance test contract requires this rendering.

### issue-acceptance finding 3 (five unit test files updated):
**not mine** — These are test files in `tests/unit/`; the build stage may not modify
test files. They were changed by the test-author stage.

## Review lenses findings — answers

### lens-security-code finding 1 / lens-red-team-code finding 1 (ZBUILD_FROM_STAGE_EMIT_START not cleared):
**wrong** — `export _ZBUILD_FROM_STAGE_EMIT_START=false` IS present in runner.sh in
the `if ! $resume_mode` fresh-run block (around line 2345), right alongside
`export _ZBUILD_RESUME_ACTIVE=false`. Stale inheritance is guarded.

### lens-security-code finding 2 / lens-correctness-code finding 3 (cyc_id sanitisation mismatch):
**not mine** — The `${_cyc_id//-/_}` vs `${_cyc_id//[^a-zA-Z0-9_-]/}` discrepancy is
pre-existing code not introduced by this branch. No acceptance test requires the fix.

### lens-performance-code findings 1 & 2:
**not mine** — Optimisations outside this issue's acceptance contract.

### lens-red-team-code finding 2 (subprocess inherits _ZBUILD_RESUME_ACTIVE during eb_emit_event):
**not mine** — Theoretical; `eb_emit_event` does not invoke the cycle orchestrator.
No acceptance test requires this defensive change.

### lens-correctness-code finding 1 (pre-scan all-complete edge case):
**wrong** — In the DSCMBR-1 scenario (build=complete, test=aborted in iter k),
`_cid_nc=1` (test is not complete), so the `_cid_nc==0` all-complete branch is never
entered. For all-complete with the wrong iter entry, `_cycle_state_write_iter_start`
always writes the iter entry before dispatching any member, so `_cid_iter_done>0`
(Scenario A: skip all, advance). The described scenario requires hand-crafted state
with no iter entry, which the production code never produces.

### lens-correctness-code finding 2 (DSCMBR-1 test sets test=aborted not complete):
**not mine** — Test file; the build stage may not modify test files.

### lens-correctness-code finding 4 (resume_mode=true override and auto-resume block):
**wrong** — Explicit `--resume` sets `resume_mode=true` before the auto-resume elif.
The elif is skipped entirely when `resume_mode=true`. The auto-resume block cannot
reset `resume_mode=false` for explicit `--resume` runs.

### lens-scope-code finding 1 (skip_restore=false unreachable):
**wrong** — S5 uses `--from-stage cyc` without `--resume` on `in_progress`. The
narrowed guard doesn't fire; auto-resume sets `resume_mode=true`; `_runner_from_stage_preflight`
is called with `skip_restore=true` (not false). S5's comment says `skip_restore=false`
but the branch is effectively `skip_restore=true`. The assertions still pass because
artifact restoration happened upstream via `_runner_resume_rehydrate`. Changing this
requires changing S5 (which I cannot do).

### lens-scope-code findings 2 & 3 (ADR-006 §3.5 in test headers):
**not mine** — Test file headers; the build stage may not modify test files.

### lens-sre-code findings 1, 2, 3 (machine-readable events missing):
**wrong** — All three events are present:
- SRE-1: `eb_emit_event "state.write" "op=iter_start" ... "reason=write_failed"` in
  cycle-orchestrator.sh after `_cycle_state_write_iter_start` failure
- SRE-2: `eb_emit_event "cycle.history.lost" ... "reason=blob_update_failed"` in
  cycle-orchestrator.sh after jq update failure for skipped member blob
- SRE-3: `eb_emit_event "state.write" "op=put_back" ... "reason=io_error"` in
  runner.sh after `_artifact_persist_put_back` failure in `_runner_resume_rehydrate`

### lens-correctness-design finding 1 (skip_until_stage clearing for cycle target):
**wrong** — When `--from-stage` names a cycle, the cycle:* arm clears BOTH
`skip_until_stage` and `resume_mode` together. After that, `resume_mode=false` so the
skip guard cannot fire for subsequent leaf stages. DSFSTG-3 tests this and passes.

## All prior iteration fixes (still present)

- DSITER-1 guard: `_ZBUILD_RESUME_ACTIVE` wraps `_persisted_iter` read; flag consumed
- DSCMBR-1 `resume_first_iter` path in cycle-orchestrator.sh
- DSFSTG-3 fix: both dispatch arms do `skip_until_stage=""; resume_mode=false`
- DSFSTG-4 guard: pre-auto-resume guard for `interrupted` + latest-symlink path
- DSENTR-2: auto-resume elif checks `$state_dir/latest/pipeline-state.json`
- ADR-006 step 3.6 with enforcing tests
- ADR-050 section 6 boundary note and Enforced by citations
- Security: `export _ZBUILD_FROM_STAGE_EMIT_START=false` in fresh-run block
- `_artifact_persist_put_back` in core/state/artifact-persist.sh
- Hydrate plugin calls `_artifact_persist_put_back`
