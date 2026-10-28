# Test stage summary

- verdict: fail
- passed: 802
- failed: 17
- exit_code: 1

## Failing files

- tests/integration/always-run-exit-paths-test.sh — ✗ [SPEC-5] a 60s release hook held the exit
- tests/integration/artifact-contract-test.sh — ✗ plugin.contract.violated event emitted — not found in /home/runner/work/_temp/zbuild-state/scratch/test/artifact-contract.1yKfId/a3/events/events.jsonl
- tests/integration/core-pipeline-runner-test.sh — ✗ happy path exits 0 — expected: 0, got: 1
- tests/integration/core-pipeline-verdict-indicators-test.sh — ✗ Pipeline cannot start — stage manifests break the contract:
- tests/integration/cycle-acceptance-terminal-failure-test.sh — ✗ Pipeline failed: status=failed run_id=20261028021215-835200 issue=0 (took 3.9s)
- tests/integration/cycle-on-max-pipeline-continues-test.sh — ✗ T1.4: pipeline.end emitted exactly once — expected: 1, got: 0
- tests/integration/design-pipeline-test.sh — ✗ runner exits 0 — expected: 0, got: 1
- tests/integration/engine-run-branch-test.sh — ✗ [E1] the first stage is already on the run's branch — expected: zbuild/issue-90090001, got: 
- tests/integration/full-pipeline-seq-cardinal-test.sh — ✗ pipeline exits 0 — expected: 0, got: 1
- tests/integration/leaf-dispatch-role-bound-verdict-test.sh — ✗ [SPEC-4] the fixture stage dispatched (stage.complete emitted)
- tests/integration/per-run-state-isolation-test.sh — ✗ T1: run-aaa exits 0 — expected: 0, got: 1
- tests/integration/pipeline-resume-test.sh — ✗ integration: --resume exits 0 when remaining stage succeeds — expected: 0, got: 1
- tests/integration/runner-exports-state-dir-test.sh — ✗ runner exits 0 — expected: 0, got: 1
- tests/integration/runner-init-state-abort-test.sh — ✗ SPEC-6: writable state dir → run completes — expected: 0, got: 1
- tests/integration/runner-release-exit-paths-test.sh — ✗ [SPEC-5] cleanup dispatched with scope=release for: intake build
- tests/integration/state-root-isolation-test.sh — ✗ nested run exits 0 — expected: 0, got: 1
- tests/integration/worktree-run-isolation-test.sh — ✗ [SPEC-3a] the build stage must commit to the work branch

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-5] a 60s release hook held the exit
    [2melapsed=62s[0m
  [38;2;248;113;113m✗[0m [SPEC-5] the hanging hook was killed before completing
    [2mfile should not exist: /home/runner/work/_temp/zbuild-state/scratch/test/zb-always-run-exit.ZqRVnY/release-ran[0m
  [38;2;248;113;113m✗[0m [#1801/SPEC-5] persist hook was entered (always_run persist stage dispatched)
    [2mfile not found: /home/runner/work/_temp/zbuild-state/scratch/test/zb-always-run-exit.ZqRVnY/spec5p-entered[0m
  [38;2;248;113;113m✗[0m plugin.contract.violated event emitted
    [2mnot found in /home/runner/work/_temp/zbuild-state/scratch/test/artifact-contract.1yKfId/a3/events/events.jsonl[0m
  [38;2;248;113;113m✗[0m synthetic findings.json created
    [2mfile not found: /home/runner/work/_temp/zbuild-state/scratch/test/artifact-contract.1yKfId/a3/state/artifacts/intake-intake-contract-violated-findings.json[0m
  [38;2;248;113;113m✗[0m plugin.contract.violated event names the expected artifact path
    [2moutput missing: intake-findings.json[0m
  [38;2;248;113;113m✗[0m plugin.contract.violated event carries reason=artifact_missing_or_empty
    [2mexpected: artifact_missing_or_empty, got: [0m
  [38;2;248;113;113m✗[0m happy path exits 0
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m pipeline.end carries status=success
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m [SPEC-1] stage.start emitted for each fixture stage (2x)
    [2mexpected: 2, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-1] stage.complete emitted for each fixture stage (2x)
    [2mexpected: 2, got: 0[0m
  [38;2;248;113;113m✗[0m intake stage_status=complete (ADR-006 enum)
    [2mexpected: complete, got: failed[0m
  [38;2;248;113;113m✗[0m build stage_status=complete (ADR-006 enum)
    [2mexpected: complete, got: [0m
  [38;2;248;113;113m✗[0m pipeline.end names the failing stage
  [38;2;248;113;113m✗[0m build stage_status=failed in state
    [2mexpected: failed, got: [0m
  [38;2;248;113;113m✗[0m kill mid-run emits pipeline.abort
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.0YS9uP/tests/integration/always-run-exit-paths-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.0YS9uP/tests/integration/artifact-contract-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.0YS9uP/tests/integration/core-pipeline-runner-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.0YS9uP/tests/integration/core-pipeline-verdict-indicators-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.0YS9uP/tests/integration/cycle-acceptance-terminal-failure-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.0YS9uP/tests/integration/cycle-on-max-pipeline-continues-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.0YS9uP/tests/integration/design-pipeline-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.0YS9uP/tests/integration/engine-run-branch-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.0YS9uP/tests/integration/full-pipeline-seq-cardinal-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.0YS9uP/tests/integration/leaf-dispatch-role-bound-verdict-test.sh
  [38;2;74;222;128m✓[0m [SPEC-6] an unresolvable always-run stage does not fail the run
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m3 of 13 tests failed[0m
  [38;2;248;113;113m[1m4 of 5 tests failed[0m
  [38;2;248;113;113m✗[0m A2 abort trap: pipeline.abort event emitted on kill
  [38;2;248;113;113m✗[0m A2 abort trap: no state.error when state file writable
  [38;2;74;222;128m✓[0m A2 abort trap: pipeline status=interrupted in state
  [38;2;248;113;113m✗[0m A3 artifact contract: plugin.contract.violated event emitted
  [38;2;248;113;113m✗[0m A3 artifact contract: synthetic findings.json not created
  [38;2;248;113;113m✗[0m all-pass: ✓ on build line
  [38;2;248;113;113m✗[0m all-pass: ✓ on test line
  [38;2;248;113;113m✗[0m stage.complete carries verdict=pass for each stage
  [38;2;248;113;113m✗[0m state.stage_verdicts.intake == pass
  [38;2;248;113;113m✗[0m test verdict=fail -> ✗ on test line
  [38;2;248;113;113m✗[0m build scope_violation=true -> ✗ on build line
  [38;2;248;113;113m✗[0m T3 [SPEC-5]: pipeline.end status=success on negctl_error:timeout (infra non-terminal)
    [2mexpected: success, got: [0m
  [38;2;74;222;128m✓[0m T3 [SPEC-5]: cycle.member.terminal_failure NOT emitted for infra timeout
  [38;2;248;113;113m[1m1 of 8 tests failed[0m
    [2mpr_run_count=0[0m
  [38;2;248;113;113m[1m3 of 7 tests failed[0m
  [38;2;248;113;113m✗[0m T1.4: pipeline.end emitted exactly once
  [38;2;248;113;113m✗[0m T1.5 (#979): pipeline.end status=failed (no review.json rescue under simple.yaml; see coupling note)
  [38;2;248;113;113m✗[0m T2.2: pr plugin did NOT run
    [2msearched under /home/runner/work/_temp/zbuild-state/scratch/test/design-pipeline-754.x1go5T/home/.zbuild[0m
  [38;2;248;113;113m[1m3 of 3 tests failed[0m
  [38;2;248;113;113m✗[0m runner exits 0
  [38;2;248;113;113m✗[0m events.jsonl contains plugin.run.start plugin=design
  [38;2;248;113;113m✗[0m design.md exists in state artifacts
  [38;2;248;113;113m[1m5 of 15 tests failed[0m
  [38;2;248;113;113m✗[0m [E1] the first stage is already on the run's branch
  [38;2;248;113;113m✗[0m [E1] ...and is told its name
  [38;2;248;113;113m✗[0m [E1] ...and the commit the

[truncated]

## The checks of this run
- the shape floor failed: missing_floor_files
