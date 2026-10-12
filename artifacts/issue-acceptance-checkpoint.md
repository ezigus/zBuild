# Issue Acceptance Checkpoint — Issue #1801

## Files read
- `/home/runner/work/_temp/zbuild-state/artifacts/test-results.json` — 21/853 tests fail; full failure details available

## Key conclusions

### R-8 UNMET
`orch-sequential-retired-guard-test.sh` fails: the guard checks `grep -rl 'orch-sequential'` excluding docs/adr/ and tests/golden/ and its own file. It finds `tests/unit/orch-backend-misconfigured-test.sh`, which references "orch-sequential" in its comment/prose text ("Before this change, orch_load_backend silently fell back to orch-sequential"). The guard test's exclusion list does not exclude this new file.

### R-2 UNMET
`runner-release-exit-paths-test.sh` fails on `[SPEC-6b] a hook child that ignores TERM does not outlive the run` — the direct test for the process-group kill requirement.

### Broad pipeline breakage (R-1, R-13)
Many integration tests fail with "intake stage_status=failed" and logs show `⚠ orch contract: orch_spawn not implemented`. Cause: backend loading (`_orch_load_backend`) tries bash-parallel; when it can't find it in test contexts it now returns 1 (hard error) instead of falling back. Since orch_spawn is never defined, the orchestrator contract call fails. This affects: core-pipeline-runner, artifact-contract, cycle-on-max, pipeline-resume, per-run-state-isolation, runner-exports-state-dir, runner-init-state-abort, cycle-acceptance-terminal-failure, full-pipeline-seq-cardinal, state-root-isolation, worktree-run-isolation, design-pipeline, build-prompt-includes-branch.

### Additional failures
- `event-schema-emitted-coverage-test.sh`: orch.backend.misconfigured and plugin.run.timed_out not in event-schema.json (breaks ADR invariant)
- `design-prompt-scope-charter-test.sh`: T6 expects design timeout_s=600, gets 3900 — pre-existing test not updated when design stage_timeout_s was added at 3900
- `runner-job-control-abort-test.sh`: `set -m` in lifecycle.sh plugin_hook_call leaks into caller runner shell, changing dash flags
- `stdin-spawn-guard-test.sh`: orch-mock pattern mismatch (changed orch-sequential → orch-mock reference doesn't match actual plugin source)

## Verdict
FAIL — R-2 integration test fails directly; R-8 guard test fails (orch-sequential reference in new test's comment); R-13 npm test fails (21 failures); broad pipeline integration failures show backend loading regression.
