# Test stage summary

- verdict: fail
- passed: 797
- failed: 21
- exit_code: 1

## Failing files

- tests/integration/always-run-exit-paths-test.sh — ✗ [SPEC-5] a 60s release hook held the exit
- tests/integration/artifact-contract-test.sh — ✗ plugin.contract.violated event emitted — not found in /home/runner/work/_temp/zbuild-state/scratch/test/artifact-contract.GLcWBD/a3/events/events.jsonl
- tests/integration/core-pipeline-runner-test.sh — ✗ happy path exits 0 — expected: 0, got: 1
- tests/integration/core-pipeline-verdict-indicators-test.sh — ✗ Pipeline cannot start — stage manifests break the contract:
- tests/integration/cycle-acceptance-terminal-failure-test.sh — ✗ Pipeline failed: status=failed run_id=20261026222851-1674108 issue=0 (took 5.2s)
- tests/integration/cycle-on-max-pipeline-continues-test.sh — ✗ T1.4: pipeline.end emitted exactly once — expected: 1, got: 0
- tests/integration/design-pipeline-test.sh — ✗ runner exits 0 — expected: 0, got: 1
- tests/integration/engine-run-branch-test.sh — ✗ [E1] the first stage is already on the run's branch — expected: zbuild/issue-92110001, got: 
- tests/integration/full-pipeline-seq-cardinal-test.sh — ✗ pipeline exits 0 — expected: 0, got: 1
- tests/integration/leaf-dispatch-role-bound-verdict-test.sh — ✗ [SPEC-4] the fixture stage dispatched (stage.complete emitted)
- tests/integration/orch-timeout-applies-test.sh — ✗ [#1801/SPEC-1] fanout strategy must propagate timed_out from _ORCH_COLLECT_OUTCOME — got '<empty>'; old code passes collect_rc=1 → _ZB_STRATEGY_OUTCOME=failed
- tests/integration/per-run-state-isolation-test.sh — ✗ T1: run-aaa exits 0 — expected: 0, got: 1
- tests/integration/pipeline-resume-test.sh — ✗ integration: --resume exits 0 when remaining stage succeeds — expected: 0, got: 1
- tests/integration/runner-exports-state-dir-test.sh — ✗ runner exits 0 — expected: 0, got: 1
- tests/integration/runner-init-state-abort-test.sh — ✗ SPEC-6: writable state dir → run completes — expected: 0, got: 1
- tests/integration/runner-release-exit-paths-test.sh — ✗ [SPEC-5] cleanup dispatched with scope=release for: intake build
- tests/integration/state-root-isolation-test.sh — ✗ nested run exits 0 — expected: 0, got: 1
- tests/integration/worktree-run-isolation-test.sh — ✗ [SPEC-3a] the build stage must commit to the work branch
- tests/unit/lint-test-errexit-test.sh — ✗ [L5] the real tree passes — expected: 0, got: 1
- tests/unit/orch-sequential-absent-guard-test.sh — ✗ [#1801/SPEC-3] no code or config file outside docs/adr/ names orch-sequential

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [L5] the real tree passes
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [#1801/SPEC-3] no code or config file outside docs/adr/ names orch-sequential
    [2mstill referenced in: /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/plugins/tool/orch-mock/tests/orch-mock-test.sh /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/tests/integration/orch-backend-misconfigured-test.sh /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/.github/issues/keepers-manifest.yaml[0m
  [38;2;248;113;113m✗[0m [SPEC-5] a 60s release hook held the exit
    [2melapsed=62s[0m
  [38;2;248;113;113m✗[0m [SPEC-5] the hanging hook was killed before completing
    [2mfile should not exist: /home/runner/work/_temp/zbuild-state/scratch/test/zb-always-run-exit.HymqJ2/release-ran[0m
  [38;2;248;113;113m✗[0m plugin.contract.violated event emitted
    [2mnot found in /home/runner/work/_temp/zbuild-state/scratch/test/artifact-contract.GLcWBD/a3/events/events.jsonl[0m
  [38;2;248;113;113m✗[0m synthetic findings.json created
    [2mfile not found: /home/runner/work/_temp/zbuild-state/scratch/test/artifact-contract.GLcWBD/a3/state/artifacts/intake-intake-contract-violated-findings.json[0m
  [38;2;248;113;113m✗[0m plugin.contract.violated event names the expected artifact path
    [2moutput missing: intake-findings.json[0m
  [38;2;248;113;113m✗[0m plugin.contract.violated event carries reason=artifact_missing_or_empty
    [2mexpected: artifact_missing_or_empty, got: [0m
  [38;2;248;113;113m✗[0m happy path exits 0
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
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/tests/unit/lint-test-errexit-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/tests/unit/orch-sequential-absent-guard-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/tests/integration/always-run-exit-paths-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/tests/integration/artifact-contract-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/tests/integration/core-pipeline-runner-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/tests/integration/core-pipeline-verdict-indicators-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/tests/integration/cycle-acceptance-terminal-failure-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/tests/integration/cycle-on-max-pipeline-continues-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/tests/integration/design-pipeline-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eQyrXm/tests/integration/engine-run-branch-test.sh
lint-test-errexit: tests/integration/orch-backend-misconfigured-test.sh:184 turns stop-on-error on in a file that runs without it (header: set -uo pipefail) — an expected non-zero rc after this line kills the file; use 'cmd || rc=$?' instead
lint-test-errexit: tests/unit/orch-kill-uses-pg-kill-guard-test.sh:133 turns stop-on-error on in a file that runs without it (header: set -uo pipefail) — an expected non-zero rc after this line kills the file; use 'cmd || rc=$?' instead
lint-test-errexit: 12 file(s) switch stop-on-error on mid-file
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 5 tests failed[0m
  [38;2;74;222;128m✓[0m [#1801/SPEC-3] orch-sequential plugin directory does not exist
  [38;2;248;113;113m[1m1 of 2 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-6] stage.always_run.unresolved is emitted
  [38;2;74;222;128m✓[0m [SPEC-6] an unresolvable always-run stage does not fail the run
  [38;2;248;113;113m[1m2 of 10 tests failed[0m
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
  [38;2;248;113;113m✗[0m test verdict=fail -> ✗

[truncated]

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — SPEC-1/SPEC-3/tests/integration/orch-timeout-applies-test.sh/tests/integration/orch-timeout-applies-test.sh/tests/integration/orch-timeout-applies-test.sh/tests/integration/orch-timeout-applies-test.sh/tests/integration/orch-timeout-applies-test.sh/tests/integration/orch-timeout-applies-test.sh: its test does not pass on the new code — the code or the test is wrong
