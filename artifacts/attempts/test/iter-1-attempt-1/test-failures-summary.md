# Test stage summary

- verdict: fail
- passed: 832
- failed: 21
- exit_code: 1

## Failing files

- tests/integration/artifact-contract-test.sh — ✗ plugin.contract.violated event emitted — not found in /home/runner/work/_temp/zbuild-state/scratch/test/artifact-contract.vdtA9M/a3/events/events.jsonl
- tests/integration/build-prompt-includes-branch-state-end-to-end-test.sh — ✗ runner exits 0 — expected: 0, got: 1
- tests/integration/core-pipeline-runner-test.sh — ✗ happy path exits 0 — expected: 0, got: 1
- tests/integration/core-pipeline-verdict-indicators-test.sh — ✗ Pipeline cannot start — inputs missing for declared stages:
- tests/integration/cycle-acceptance-terminal-failure-test.sh — ✗ Pipeline failed: status=failed run_id=20261012021142-1579736 issue=0 (took 19.4s)
- tests/integration/cycle-on-max-pipeline-continues-test.sh — ✗ T1.4: pipeline.end emitted exactly once — expected: 1, got: 0
- tests/integration/design-pipeline-test.sh — ✗ runner exits 0 — expected: 0, got: 1
- tests/integration/full-pipeline-seq-cardinal-test.sh — ✗ pipeline exits 0 — expected: 0, got: 1
- tests/integration/leaf-dispatch-role-bound-verdict-test.sh — ✗ [SPEC-4] the fixture stage dispatched (stage.complete emitted)
- tests/integration/per-run-state-isolation-test.sh — ✗ T1: run-aaa exits 0 — expected: 0, got: 1
- tests/integration/pipeline-resume-test.sh — ✗ integration: --resume exits 0 when remaining stage succeeds — expected: 0, got: 1
- tests/integration/runner-exports-state-dir-test.sh — ✗ runner exits 0 — expected: 0, got: 1
- tests/integration/runner-init-state-abort-test.sh — ✗ SPEC-6: writable state dir → run completes — expected: 0, got: 1
- tests/integration/runner-job-control-abort-test.sh — ✗ flag-off: monitor mode OFF in runner shell — got: dash=hmuB
- tests/integration/runner-release-exit-paths-test.sh — ✗ [SPEC-6b] a hook child that ignores TERM does not outlive the run
- tests/integration/state-root-isolation-test.sh — ✗ nested run exits 0 — expected: 0, got: 1
- tests/integration/worktree-run-isolation-test.sh — ✗ [SPEC-3a] the build stage must commit to the work branch
- tests/unit/design-prompt-scope-charter-test.sh — ✗ T6: design timeout_s raised to 600 — expected: 600, got: 3900
- tests/unit/event-schema-emitted-coverage-test.sh — ✗ emitted type 'orch.backend.misconfigured' is in the composed known set
- tests/unit/orch-sequential-retired-guard-test.sh — ✗ [#1801/SPEC-8] no file outside docs/adr/ names orch-sequential — found references:
- tests/unit/stdin-spawn-guard-test.sh — ✗ [#2108] orch-mock work units close stdin — pattern not found in plugins/tool/orch-mock/plugin.sh: bash -c "\$task_body" .* </dev/null

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1801/SPEC-8] no file outside docs/adr/ names orch-sequential
    [2mfound references:
  [38;2;248;113;113m✗[0m emitted type 'orch.backend.misconfigured' is in the composed known set
    [2mnot in config/event-schema.json nor any manifest's provides.events[0m
  [38;2;248;113;113m✗[0m emitted type 'plugin.run.timed_out' is in the composed known set
  [38;2;248;113;113m✗[0m T6: design timeout_s raised to 600
    [2mexpected: 600, got: 3900[0m
  [38;2;248;113;113m✗[0m [#2108] orch-mock work units close stdin
    [2mpattern not found in plugins/tool/orch-mock/plugin.sh: bash -c "\$task_body" .* </dev/null[0m
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
  [38;2;74;222;128m✓[0m --template runner-state-dir-minimal dry-run shows intake
  [38;2;248;113;113m✗[0m role-based dispatch exits 0
  [38;2;248;113;113m✗[0m role-based dispatch: 2 stage.complete events
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pmUGkJ/tests/unit/orch-sequential-retired-guard-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pmUGkJ/tests/unit/event-schema-emitted-coverage-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pmUGkJ/tests/unit/design-prompt-scope-charter-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pmUGkJ/tests/unit/stdin-spawn-guard-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pmUGkJ/tests/integration/core-pipeline-runner-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pmUGkJ/tests/integration/artifact-contract-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pmUGkJ/tests/integration/cycle-on-max-pipeline-continues-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pmUGkJ/tests/integration/pipeline-resume-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pmUGkJ/tests/integration/per-run-state-isolation-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pmUGkJ/tests/integration/cycle-acceptance-terminal-failure-test.sh
  [38;2;74;222;128m✓[0m [#1801/SPEC-11] ADR-054 is not in adr-enforcement-baseline.txt
  [38;2;74;222;128m✓[0m [#1801/SPEC-11] ADR-017 is not in adr-enforcement-baseline.txt
  [38;2;74;222;128m✓[0m [#1801/SPEC-11] ADR-011 is not in adr-enforcement-baseline.txt
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 9 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-5] redaction.marker_neutralized is registered in event-schema.json known_types
  [38;2;74;222;128m✓[0m [#2032] cycle.member_unfinished.suppressed_convergence is registered in event-schema.json known_types
  [38;2;248;113;113m[1m2 of 7 tests failed[0m
  [38;2;74;222;128m✓[0m T5: prompt keeps design read-only (no Edit/Write/Bash for impl)
  [38;2;248;113;113m[1m1 of 7 tests failed[0m
  [38;2;74;222;128m✓[0m [#2108] local_engine work units close stdin
  [38;2;248;113;113m[1m1 of 8 tests failed[0m
  [38;2;248;113;113m✗[0m A2 abort trap: pipeline.abort event emitted on kill
  [38;2;248;113;113m✗[0m A2 abort trap: no state.error when state file writable
  [38;2;74;222;128m✓[0m A2 abort trap: pipeline status=interrupted in state
  [38;2;248;113;113m✗[0m A3 artifact contract: plugin.contract.violated event emitted
  [38;2;248;113;113m✗[0m A3 artifact contract: synthetic findings.json not created
  [38;2;248;113;113m[1m4 of 5 tests failed[0m
  [38;2;248;113;113m✗[0m plugin.contract.violated event emitted
  [38;2;248;113;113m✗[0m synthetic findings.json created
  [38;2;248;113;113m✗[0m plugin.contract.violated event names the expected artifact path
  [38;2;248;113;113m✗[0m plugin.contract.violated event carries reason=artifact_missing_or_empty
    [2mpr_run_count=0[0m
  [38;2;248;113;113m[1m3 of 7 tests failed[0m
  [38;2;248;113;113m✗[0m T1.4: pipeline.end emitted exactly once
  [38;2;248;113;113m✗[0m T1.5 (#979): pipeline.end status=failed (no review.json rescue under simple.yaml; see coupling note)
  [38;2;248;113;113m✗[0m T2.2: pr plugin did NOT run
  [38;2;74;222;128m✓[0m --from-stage without --resume exits 1
  [38;2;74;222;128m✓[0m --

[truncated]
