# Gate Aggregator Feedback

The build_test_cycle did not converge: 2 mechanical gate(s) failed. Address every finding below, then re-run.

## test

- test output:
```

> zbuild@0.1.0 test
> bash tests/run-all.sh

unit: 368/370 passed (4 skipped)
integration: 226/235 passed
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
  PASS  orch.md  (caught: rc=1)
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
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/unit/test-plugin-result-write-fallback-test.sh

  test-plugin _test_write_result defensive fallback (#626)


  1. whitespace in passed slot triggers fallback
  ✓ ws-passed: results file written
  ✓ ws-passed: results file is valid JSON
  ✓ ws-passed: no jq error leaked to stderr
  ✓ ws-passed: .passed sanitized to null

  2. non-numeric failed slot triggers sanitizer
  ✓ abc-failed: results file written
  ✓ abc-failed: results file is valid JSON
  ✓ abc-failed: no jq error leaked to stderr
  ✓ abc-failed: .failed sanitized to null

  3. control-char test_output is accepted, JSON still valid
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/unit/readout-gates-test.sh

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

integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/test-plugin-fresh-shell-test.sh

  integration: test-plugin fresh-user-shell scrub (#671)


  1. eval subshell has NO ZBUILD_* env and fd 3 is closed
  ✓ test-results.json written
  ✗ subshell exit_code is 0 (all ZBUILD_* unset AND fd 3 closed)
    expected: 0, got: null
  ✗ test_output should contain 'OK: fresh shell', got: null
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/test-plugin-runs-against-committed-head-test.sh

  integration: test plugin runs against committed HEAD (Wave 12-C #662)


  1. tests run against committed HEAD (no apply)
  ✓ test-results.json written
  ✓ no diff_apply_failed verdict (reason='')
  ✓ verdict=pass from parsed test_cmd output
  ✗ test_cmd executed against rsync'd HEAD
    marker 'ZBUILD_W12C_MARKER_6943' missing from .test_output: null
  ✗ .exit_code is numeric
    got: null

  2. plugin.sh source has no git apply on diff.patch
  ✓ plugin.sh contains no 'git apply' call (non-comment)
  ✓ plugin.sh has no diff_apply_failed verdict path (non-comment)

  3. manifest.yaml removes diff_patch input declaration
  ✓ manifest.yaml has no diff_patch input declaration


  2 of 8 tests failed

  ✗ test_cmd executed against rsync'd HEAD
  ✗ .exit_code is numeric

integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/build-test-cycle-targeted-rerun-test.sh

  build_test_cycle: real targeted re-run + full-suite gate (#846)

--- banner ---
(no feedback — first iteration)


exit_when stage=test field=verdict op=eq value=pass → NOT MATCHED (got=fail)
health: progress=0 (no progress) - defects=0 → score=0

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

integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/test-plugin-stage-io-banner-visible-test.sh

  integration: test-plugin stage-io banner visible (#645)


  1. capture_stage_io banner from test subshell is visible in test_output
  ✓ test-results.json written
  ✗ test_cmd did not produce marker; got: null
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/test-plugin-tmpdir-cleanup-test.sh

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

integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/test-plugin-summary-format-test.sh

  integration: test-plugin parser → test-results.json (#584)


  1. jest-shaped output parsed correctly
  ✓ jest: artifact written
  ✓ jest: verdict=fail
  ✗ jest: passed=108
    expected: 108, got: null
  ✗ jest: failed=18
    expected: 18, got: null

  2. pytest-shaped output parsed correctly
  ✓ pytest: verdict=fail
  ✗ pytest: passed=42
    expected: 42, got: null
  ✗ pytest: failed=3
    expected: 3, got: null

  3. run-all-shaped output parsed correctly
  ✓ runall: verdict=fail
  ✗ runall: passed=191
    expected: 191, got: null
  ✗ runall: failed=1
    expected: 1, got: null

  4. unrecognized output → reason=summary_unavailable + null counts
  ✓ failsafe: verdict=error
  ✓ failsafe: reason=summary_unavailable
  ✓ failsafe: passed is null
  ✓ failsafe: failed is null

  5. empty output (no-op cmd) → verdict=error
  ✓ noop: verdict=error


  6 of 15 tests failed

  ✗ jest: passed=108
  ✗ jest: failed=18
  ✗ pytest: passed=42
  ✗ pytest: failed=3
  ✗ runall: passed=191
  ✗ runall: failed=1

integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/pipeline-test-stage-fresh-shell-test.sh

  integration: pipeline test stage _TPL_* leak (Wave 15-I / #683)


  1. test-plugin-fresh-shell-test passes under leaked _TPL_*

  integration: test-plugin fresh-user-shell scrub (#671)


  1. eval subshell has NO ZBUILD_* env and fd 3 is closed
  ✓ test-results.json written
  ✗ subshell exit_code is 0 (all ZBUILD_* unset AND fd 3 closed)
    expected: 0, got: null
  ✗ test_output should contain 'OK: fresh shell', got: null
  ✗ test-plugin-fresh-shell-test exited rc=1 (expected 0)

  2. core-router-route-test (Tr-5) passes under leaked _TPL_*
  ✓ core-router-route-test exits 0 under leaked _TPL_*

  3. _zbuild_make_fresh_shell scrubs _TPL_* (post-condition)
  ✓ no _TPL_* env vars remain after scrub


  1 of 3 tests failed
```

## acceptance-gate

- reason: acceptance SPEC violations — SPEC-1/SPEC-2/SPEC-3/SPEC-4/SPEC-5/SPEC-6/SPEC-7 not passing at HEAD — fix the implementation or the assertion; WIRING plugins/tool/test/manifest.yaml inert — reverting it breaks no TESTFILE; infra: negctl_error:harness:SPEC-8/negctl_error:harness:SPEC-9/negctl_error:harness:SPEC-10
- failures:
    - not_passing_at_head:SPEC-1
    - not_passing_at_head:SPEC-2
    - not_passing_at_head:SPEC-3
    - not_passing_at_head:SPEC-4
    - not_passing_at_head:SPEC-5
    - not_passing_at_head:SPEC-6
    - not_passing_at_head:SPEC-7
    - negctl_error:harness:SPEC-8
    - negctl_error:harness:SPEC-9
    - negctl_error:harness:SPEC-10
    - inert_wiring:plugins/tool/test/manifest.yaml

## Handled elsewhere

- 1 further gate(s) route to `design` and are addressed there, not by build: shape-floor

