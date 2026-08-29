# Gate Aggregator Feedback

The build_test_cycle did not converge: 1 mechanical gate(s) failed. Address every finding below, then re-run.

## test

- test output:
```

> zbuild@0.1.0 test
> bash tests/run-all.sh

unit: 369/370 passed (4 skipped)
integration: 231/235 passed
e2e: 8/8 passed
golden: 1/1 passed

─── Mutation test results ──────────────────────────────
  PASS  atomic-state-mutations.md  (caught: rc=3)
  PASS  cache.md  (caught: rc=1)
  PASS  cleanup-worktree-age-guard.md  (caught: rc=2)
  PASS  cleanup-worktree-dirty-guard.md  (caught: rc=2)
  PASS  detect-platforms.md  (caught: rc=11)
  PASS  event-bus-ansi-strip.md  (caught: rc=4)
  PASS  event-bus.md  (caught: rc=3)
  INFRA memory.md  (patch failed after retries)
  PASS  orch.md  (caught: rc=2)
  PASS  output-destinations.md  (caught: rc=1)
  PASS  pipeline-contracts.md  (caught: rc=127)
  PASS  pipeline-dispatch-arg-mutations.md  (caught: rc=4)
  PASS  pipeline-dispatch-failopen-mutations.md  (caught: rc=7)
  PASS  pipeline-dispatch-mutations.md  (caught: rc=9)
  PASS  pipeline-dispatch-prefix-mutations.md  (caught: rc=1)
  PASS  pipeline-dispatch-selfsource-mutations.md  (caught: rc=1)
  PASS  pipeline-resolver.md  (caught: rc=1)
  PASS  rc-semantics.md  (caught: rc=1)
  PASS  registry-role-resolution.md  (caught: rc=1)
  PASS  registry-validate-manifest-mutations.md  (caught: rc=1)
  PASS  resume-recommendation-mutations.md  (caught: rc=1)
  PASS  router-route-mutations.md  (caught: rc=1)
  PASS  runner-fail-closed-mutations.md  (caught: rc=127)
  PASS  scope-redaction-mutations.md  (caught: rc=3)
mutation-infra: 1 non-fatal (worktree/patch contention; excluded from score — #1184)
mutation: 23/23 passed
lint: 1/1 passed
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.KrOd8W/tests/unit/readout-gates-test.sh

  read-out gates — lint/coverage/mutation (#1135, ADR-040)

  ✓ [L1] lint pass: rc=0
  ✗ [L1] lint pass → verdict=pass
    key .verdict: expected pass, got: skip
  ✗ [L2] lint fail → verdict=fail
    key .verdict: expected fail, got: skip
  ✓ [L3] lint skipped → verdict=skip
  ✓ [L4] missing lint block → verdict=skip
  ✓ [L5] absent test-results → verdict=skip
  ✓ [C1] coverage pass: rc=0
  ✗ [C1] measured pct>=floor → verdict=pass
    key .verdict: expected pass, got: skip
  ✗ [C2] measured pct<floor → verdict=fail
    key .verdict: expected fail, got: skip
  ✗ [C3] status below_floor → verdict=fail
    key .verdict: expected fail, got: skip
  ✓ [C4] status skipped → verdict=skip
  ✓ [C5] status error → verdict=skip
  ✗ [C6] recorded floor wins → verdict=fail
    key .verdict: expected fail, got: skip
  ✗ [C6] recorded floor reported
    key .floor: expected 50, got: 10
  ✓ [C7] missing coverage block → verdict=skip
  ✓ [M1] mutation pass: rc=0
  ✗ [M1] measured N>=floor → verdict=pass
    key .verdict: expected pass, got: skip
  ✗ [M2] measured N<floor → verdict=fail
    key .verdict: expected fail, got: skip
  ✓ [M3] status skipped → verdict=skip
  ✗ [M4] default floor 0 → verdict=pass
    key .verdict: expected pass, got: skip
  ✓ [M5] missing mutation block → verdict=skip
  ✓ [M6] absent test-results → verdict=skip


  10 of 22 tests failed

  ✗ [L1] lint pass → verdict=pass
  ✗ [L2] lint fail → verdict=fail
  ✗ [C1] measured pct>=floor → verdict=pass
  ✗ [C2] measured pct<floor → verdict=fail
  ✗ [C3] status below_floor → verdict=fail
  ✗ [C6] recorded floor wins → verdict=fail
  ✗ [C6] recorded floor reported
  ✗ [M1] measured N>=floor → verdict=pass
  ✗ [M2] measured N<floor → verdict=fail
  ✗ [M4] default floor 0 → verdict=pass

integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.KrOd8W/tests/integration/build-test-cycle-targeted-rerun-test.sh

  build_test_cycle: real targeted re-run + full-suite gate (#846)

--- banner ---
(no feedback — first iteration)


exit_when stage=test field=verdict op=eq value=pass → NOT MATCHED (got=fail)
health: progress=0 (no progress) - defects=1 → score=-1

(no feedback — first iteration)


exit_when stage=test field=verdict op=eq value=pass → MATCHED (got=pass)
health: progress=0 (no progress) - defects=0 → score=0
targeted pass — running full suite to confirm before converging

(no feedback — first iteration)


exit_when stage=test field=verdict op=eq value=pass → MATCHED (got=pass)
health: progress=0 (no progress) - defects=0 → score=0
--- run_modes ---
iter=1 run_mode=?
iter=2 run_mode=?
iter=3 run_mode=?
  ✗ T1: iter-2 test stage runs run_mode=targeted (red-set engaged)
    expected: targeted, got: ?
  ✓ T2: cycle.test.full_suite_gate emitted on targeted convergence
  ✗ T3: iter-3 (gate) runs full suite
    expected: full, got: ?
  ✓ T4: cycle converged (rc=0)
  ✓ T5: reason=converged
  ✓ T6: operator line explains the held targeted pass (full-suite confirm)


  2 of 6 tests failed

  ✗ T1: iter-2 test stage runs run_mode=targeted (red-set engaged)
  ✗ T3: iter-3 (gate) runs full suite

integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.KrOd8W/tests/integration/test-plugin-stage-io-banner-visible-test.sh

  integration: test-plugin stage-io banner visible (#645)


  1. capture_stage_io banner from test subshell is visible in test_output
  ✓ test-results.json written
  ✗ test_cmd did not produce marker; got: null
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.KrOd8W/tests/integration/test-plugin-tmpdir-cleanup-test.sh

  integration: _test_run_inner tmpdir self-cleanup (#628)


  1. missing diff.patch (early-return guard)
  ✓ missing-diff: artifact still written
  ✓ missing-diff: no zbuild-test-stage.* leaked in TMPDIR

  2. non-empty diff.patch path (W12-C: diff ignored, tmpdir still cleaned)
  ✓ non-empty-diff: verdict=pass (diff ignored, test_cmd parsed)
  ✓ non-empty-diff: no diff_apply_failed reason (reason='')
  ✓ non-empty-diff: no zbuild-test-stage.* leaked in TMPDIR

  3. success path (empty diff + trivial passing cmd)
  ✗ success: artifact written
    expected: 0, got: null
  ✓ success: no zbuild-test-stage.* leaked in TMPDIR

  4. [SPEC-5] test_cleanup(purge) is the lifecycle-correct rm-rf path
  ✓ [SPEC-5] test_cleanup(purge) removes the staging directory


  1 of 8 tests failed

  ✗ success: artifact written

integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.KrOd8W/plugins/tool/test/tests/test-test.sh

  plugin: test-stage (tool/test — issue #342)


  2. missing diff.patch → error artifact
  ✓ plugin exits 0 even when diff.patch missing (exit 0)
  ✓ test-results.json written on missing patch
  ✓ verdict is 'error' for missing patch
  ✓ diff_applied is false for missing patch

  3. good diff.patch + passing test_cmd → pass
  ✓ plugin exits 0 on passing test (exit 0)
  ✓ test-results.json written for passing test
  ✓ verdict is 'pass'
  ✓ exit_code is 0
  ✓ diff_applied is false (W12-C deprecated)

  4. failing test_cmd → verdict=fail, plugin exits 0
  ✓ plugin exits 0 even when tests fail (exit 0)
  ✓ test-results.json written for failing test
  ✓ verdict is 'fail' when test_cmd exits 1
  ✓ exit_code is 1 in artifact

  4b. #485: no-op test_cmd → verdict=error (silent-failure guard)
  ✓ plugin still exits 0 on no-op run (exit 0)
  ✓ test-results.json written
  ✓ #485 no-op: verdict=error (not pass)
  ✓ #485 no-op: exit_code=0 still recorded
  ✓ #485/#584 no-op: passed=null (honest)
  ✓ #485/#584 no-op: failed=null (honest)

  6. #497 input banner emitted; kind=command; contains test_cmd
  ✓ _test_run_inner exits 0 (exit 0)
  ✓ input banner emitted to fd 3
  ✓ banner kind is command
  ✓ banner references stage=test
  ✓ input banner shows test_cmd path

  7. #497 pass verdict → output summary 'N passed, M failed'
  ✓ output summary: jest '47 passed, 0 failed'
  ✓ output banner present (seq=1 output)
  ✓ end stage-io trailer present

  8. #497 fail verdict → summary has '(exit N)' suffix
  ✓ fail summary: jest '44 passed, 3 failed (exit 1)'

  9a. #497 #485 no-op guard → 'no-op: 0 tests detected'
  ✓ no-op summary: 'summary unavailable'

  10. #497 input banner timestamp < output banner timestamp
  ✓ input banner found in stream
  ✓ output banner found in stream
  ✓ input banner line precedes output banner line
  ✓ wall delta >= 1s proves bracketing window (delta=2s)

  11. #497 subprocess-boundary integration on fd 3
  ✓ driver subprocess exits 0 (exit 0)
  ✓ [subprocess] input banner on fd 3
  ✓ [subprocess] output banner on fd 3
  ✓ [subprocess] summary in output banner (jest)
  ✓ [subprocess] test-results.json still written
  ✓ [subprocess] verdict=pass preserved

  12. #602: dirty WT rsyncs intact (no reset, no apply)
  ✓ #548: plugin exits 0 with dirty working tree (exit 0)
  ✓ #548: test-results.json written
  ✓ #548: verdict=pass (patch applied against clean HEAD)
  ✓ W12-C: diff_applied=false (deprecated)

  T13. _test_extract_failing_files extracts FAIL paths
  ✓ T13: foo-test.sh present
  ✓ T13: bar-test.sh present
  ✓ T13: exactly 2 paths extracted

  T13b. _test_extract_failing_files returns empty on all-pass
  ✓ T13b: empty output when no FAIL lines

  T14. _test_compute_target_files unions red-set and grep-affected
  ✓ T14: red-set path included
  ✓ T14: grep-matched path included
  ✓ T14: unrelated test not included
  ✓ T14b: unresolvable red-set hint dropped (advisory, not a target)

  T15. _test_build_targeted_cmd renders the {files} template
  ✓ T15: {files} replaced with the quoted file list
  ✓ T15: cmd references bar-test.sh
  ✓ T15: empty template returns empty
  ✓ T15: empty file list returns empty

  T16. _test_run_inner with ZBUILD_TEST_RED_SET writes run_mode=targeted
  ✓ T16: plugin exits 0 (exit 0)
  ✓ T16: test-results.json written
  ✓ T16: run_mode=targeted written to JSON

  T17. ZBUILD_TEST_FULL_SUITE_GATE=1 forces full suite, run_mode=full
  ✓ T17: plugin exits 0 (exit 0)
  ✓ T17: test-results.json written
  ✓ T17: run_mode=full (gate forces full suite)

  T18. clean run removes a stale test-red-set.json
  ✓ T18: stale red-set removed after a no-failure run

  SPEC. v2 result contract (#1836)
  ✓ [SPEC-1] result_contract=2 at top level
  ✓ [SPEC-2] disposition field present in v2 result
  ✓ [SPEC-3] disposition=complete when verdict=pass
  ✓ [SPEC-4] disposition=complete when verdict=fail
  ✓ [SPEC-5] disposition=broken on error (missing diff)
  ✓ [SPEC-6] reason=missing_diff_pa
```

## Handled elsewhere

- 2 further gate(s) route to `design` and are addressed there, not by build: shape-floor acceptance-gate

