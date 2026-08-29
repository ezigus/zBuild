# Gate Aggregator Feedback

The build_test_cycle did not converge: 1 mechanical gate(s) failed. Address every finding below, then re-run.

## test

- test output:
```
unit: FAIL plugins/tool/test/tests/test-test.sh

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
  ✓ [SPEC-6] reason=missing_diff_patch emitted on missing diff
  ✓ [SPEC-7] exit_code lives under data block
  ✓ [SPEC-7] exit_code absent at top level
  ✓ [SPEC-8] rc=143 (SIGTERM) → disposition=interrupted
  ✓ [SPEC-8] rc=137 (SIGKILL) → disposition=interrupted
  ✓ [SPEC-8] rc=130 (SIGINT) → disposition=interrupted
  ✓ [SPEC-8] rc=1 (non-signal error) → disposition=broken (not interrupted)
  ✗ [SPEC-9] _test_write_result does not construct artifact paths from artifact_dir
    expected: 0, got: 0
0
  ✓ [SPEC-10] valid_verdicts covers pass
  ✓ [SPEC-10] valid_verdicts covers fail
  ✓ [SPEC-10] valid_verdicts covers error


  1 of 78 tests failed

  ✗ [SPEC-9] _test_write_result does not construct artifact paths from artifact_dir

unit: FAIL tests/integration/test-plugin-tmpdir-cleanup-test.sh

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

unit: 58/60 passed
```

## Handled elsewhere

- 1 further gate(s) route to `design` and are addressed there, not by build: acceptance-gate

