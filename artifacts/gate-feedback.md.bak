# Gate Aggregator Feedback

The build_test_cycle did not converge: 2 mechanical gate(s) failed. Address every finding below, then re-run.

## test

- test output:
```
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

unit: 1/2 passed
```

## acceptance-gate

- reason: acceptance SPEC violations — SPEC-1/SPEC-2/SPEC-3/SPEC-4/SPEC-5/SPEC-6/SPEC-7/SPEC-8/SPEC-11 tautological (pass at baseline) — re-author the assertions
- failures:
    - tautology:SPEC-1
    - tautology:SPEC-2
    - tautology:SPEC-3
    - tautology:SPEC-4
    - tautology:SPEC-5
    - tautology:SPEC-6
    - tautology:SPEC-7
    - tautology:SPEC-8
    - tautology:SPEC-11

