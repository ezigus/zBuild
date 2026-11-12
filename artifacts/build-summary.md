## build — pass

- changed no file

- over 1 pass(es), 1 iteration(s)
- answered: issue-acceptance finding 1: wrong — the test is wrong: tests/integration/from-stage-rehydrate-test.sh: The S5 sub-test (tagged [#1805/DSFSTG-1]) runs `--from-stage cyc` without `--resume` on `status=in_progress` and asserts SUCCESS. The same acceptance file contains DSFSTG-4 tests (S11, S12) that require `--from-stage` without `--resume` on `status=interrupted` to FAIL. Satisfying both requires the narrowed guard (fires only for `interrupted`). Broadening the guard to catch `in_progress` too (which would satisfy RQFROM-4 in full) breaks S5. The two tests in the same acceptance file are mutually incompatible with RQFROM-4 in full — S5 needs to either use `--resume` or use a state that does not trigger auto-resume.
- answered: issue-acceptance finding 2: wrong — `tests/unit/descriptive-id-readers-test.sh` is in the acceptance test list and asserts the backtick-pair rendering; reverting `run-status-text.sh` breaks that acceptance test.
- answered: issue-acceptance finding 3: not mine — these are test files in `tests/unit/`; the build stage may not modify test files. They were changed by the test-author stage as a consequence of the run-status-text.sh change.
- answered: lens-security-code finding 1: wrong — `export _ZBUILD_FROM_STAGE_EMIT_START=false` is present in runner.sh in the `if ! $resume_mode` fresh-run block (around line 2345), right alongside `export _ZBUILD_RESUME_ACTIVE=false`. Stale inheritance is already guarded.
- answered: lens-security-code finding 2: not mine — pre-existing sanitisation discrepancy not introduced by this branch; no acceptance test requires the fix.
- answered: lens-performance-code finding 1: not mine — optimisation outside this issue's acceptance contract.
- answered: lens-performance-code finding 2: not mine — optimisation outside this issue's acceptance contract.
- answered: lens-red-team-code finding 1: wrong — `export _ZBUILD_FROM_STAGE_EMIT_START=false` is present in the fresh-run block alongside `_ZBUILD_RESUME_ACTIVE=false`; stale inheritance is guarded.
- answered: lens-red-team-code finding 2: not mine — theoretical risk; `eb_emit_event` does not invoke the cycle orchestrator; no acceptance test requires this defensive change.
- answered: lens-correctness-code finding 1: wrong — in the DSCMBR-1 scenario (build=complete, test=aborted), `_cid_nc=1` so the `_cid_nc==0` all-complete branch is never entered. The all-complete + absent-iter-entry scenario (Scenario B) only arises with hand-crafted state; `_cycle_state_write_iter_start` always writes the iter entry before any member dispatches, so `_cid_iter_done>0` for any iter that actually started.
- answered: lens-correctness-code finding 2: not mine — test file; the build stage may not modify test files.
- answered: lens-correctness-code finding 3: not mine — pre-existing sanitisation gap not introduced by this branch; no acceptance test requires the fix.
- answered: lens-correctness-code finding 4: wrong — explicit `--resume` sets `resume_mode=true` before the auto-resume `elif` block; the `elif` is skipped entirely when `resume_mode=true`, so the auto-resume block cannot reset `resume_mode=false` for explicit `--resume` runs.
- answered: lens-scope-code finding 1: wrong — S5 uses `--from-stage cyc` without `--resume` on `in_progress`; the narrowed guard doesn't fire; auto-resume sets `resume_mode=true`; `_runner_from_stage_preflight` is called with `skip_restore=true` (not false). S5's comment says `skip_restore=false` but the runtime path is `skip_restore=true` because auto-resume set `resume_mode=true` first. Changing this requires changing S5 (which I cannot do).
- answered: lens-scope-code finding 2: not mine — test file header; the build stage may not modify test files.
- answered: lens-scope-code finding 3: not mine — test file header; the build stage may not modify test files.
- answered: lens-sre-code finding 1: wrong — `eb_emit_event "state.write" "op=iter_start" ... "reason=write_failed"` is emitted in cycle-orchestrator.sh after `_cycle_state_write_iter_start` failure.
- answered: lens-sre-code finding 2: wrong — `eb_emit_event "cycle.history.lost" ... "reason=blob_update_failed"` is emitted in cycle-orchestrator.sh after jq update failure for the skipped member blob.
- answered: lens-sre-code finding 3: wrong — `eb_emit_event "state.write" "op=put_back" ... "reason=io_error"` is emitted in runner.sh after `_artifact_persist_put_back` failure in `_runner_resume_rehydrate`.
- answered: lens-correctness-design finding 1: wrong — when `--from-stage` names a cycle, the cycle:* arm clears both `skip_until_stage` and `resume_mode` together (`skip_until_stage=""; resume_mode=false`). After that point `resume_mode=false`, so the skip guard cannot fire for subsequent leaf stages. DSFSTG-3 tests this scenario and passes.
