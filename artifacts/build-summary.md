## build — pass

- changed no file

- over 1 pass(es), 1 iteration(s)
- answered: test finding 1: not mine — the test must change: tests/integration/from-stage-rehydrate-test.sh: S5 (around line 221) and S6 (around line 468) use `--from-stage` without `--resume` on `status=in_progress` and expect SUCCESS (artifact rehydration, cycle.start, stage.start). Making the guard fire for ALL states (which pipeline-resume-test.sh requires to pass) also fires for `in_progress`, breaking S5 and S6 (6 tests). The design decision (Gap 12 §(c)) explicitly says S5 must be updated to use `--resume --from-stage cyc`; the test-author stage had an error verdict and did not update them. The build stage cannot modify test files.
- answered: shape-floor finding 1: wrong — not reproduced: `git diff HEAD -- tests/golden/full-pipeline/event-sequence.golden` shows no changes to this file. Code changes in this branch only affect flows gated by `--resume`/`--from-stage` flags; the full-pipeline golden flow is unaffected. The `_cd_iter > 0` unconditional stage.start guard is not present in the current code.
- answered: shape-floor finding 2: wrong — not reproduced: `git diff HEAD -- tests/golden/parity/event-sequence.golden` shows no changes to this file. Same reasoning as finding 1.
- answered: issue-acceptance finding 1: not mine — fixing RQFROM-4 fully (broadening the guard to all states, including `in_progress`) breaks `from-stage-rehydrate-test.sh` S5 and S6, which are acceptance tests that use `--from-stage` without `--resume` on `status=in_progress` and expect SUCCESS. The design decision (Gap 12 §(c)) requires S5/S6 to be updated to use `--resume --from-stage`; the test-author stage had an error verdict and did not update them. The build stage cannot modify test files.
- answered: issue-acceptance finding 2: wrong — `descriptive-id-readers-test.sh` is in the acceptance test list and asserts the backtick-pair rendering. The acceptance test contract requires this rendering; reverting `run-status-text.sh` would break that acceptance test.
- answered: issue-acceptance finding 3: not mine — these are test files; the build stage may not modify test files. They were changed by the test-author stage.
- answered: lens-security-code finding 1: wrong — `export _ZBUILD_FROM_STAGE_EMIT_START=false` IS present in runner.sh in the `if ! $resume_mode` fresh-run block alongside `export _ZBUILD_RESUME_ACTIVE=false`.
- answered: lens-security-code finding 2: not mine — pre-existing sanitisation discrepancy not introduced by this branch; no acceptance test requires the fix.
- answered: lens-performance-code finding 1: not mine — optimisation outside acceptance contract.
- answered: lens-performance-code finding 2: not mine — optimisation outside acceptance contract.
- answered: lens-red-team-code finding 1: wrong — `export _ZBUILD_FROM_STAGE_EMIT_START=false` IS present in the fresh-run block alongside `_ZBUILD_RESUME_ACTIVE=false`.
- answered: lens-red-team-code finding 2: not mine — theoretical risk; `eb_emit_event` does not invoke the cycle orchestrator; no acceptance test requires this defensive change.
- answered: lens-correctness-code finding 1: wrong — in the DSCMBR-1 scenario (build=complete, test=aborted in iter k), `_cid_nc=1` so the all-complete branch (`_cid_nc==0`) is never entered.
- answered: lens-correctness-code finding 2: not mine — test file; build stage cannot modify test files.
- answered: lens-correctness-code finding 3: not mine — pre-existing sanitisation gap not introduced by this branch; no acceptance test requires the fix.
- answered: lens-correctness-code finding 4: wrong — explicit `--resume` sets `resume_mode=true` before the auto-resume elif block; the elif is skipped entirely when `resume_mode=true`, so it cannot reset `resume_mode=false`.
- answered: lens-scope-code finding 1: not mine — removing `skip_restore=false` requires S5 and S6 in from-stage-rehydrate-test.sh to be updated first (they test this path); those are test files the build stage cannot modify.
- answered: lens-scope-code finding 2: not mine — test file header; build stage cannot modify test files.
- answered: lens-scope-code finding 3: not mine — test file header; build stage cannot modify test files.
- answered: lens-sre-code finding 1: wrong — `eb_emit_event "state.write" "op=iter_start" ... "reason=write_failed"` is emitted in cycle-orchestrator.sh after `_cycle_state_write_iter_start` failure.
- answered: lens-sre-code finding 2: wrong — `eb_emit_event "cycle.history.lost" ... "reason=blob_update_failed"` is emitted in cycle-orchestrator.sh after jq update failure for the skipped member blob.
- answered: lens-sre-code finding 3: wrong — `eb_emit_event "state.write" "op=put_back" ... "reason=io_error"` is emitted in runner.sh after `_artifact_persist_put_back` failure in `_runner_resume_rehydrate`.
- answered: lens-correctness-design finding 1: wrong — when `--from-stage` names a cycle, the cycle:* arm clears both `skip_until_stage` and `resume_mode` together; after that point `resume_mode=false` so the skip guard cannot fire for subsequent leaf stages. DSFSTG-3 tests this scenario and passes.
