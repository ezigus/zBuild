# Test stage summary

- verdict: fail
- passed: 819
- failed: 2
- exit_code: 1

## Failing files

- tests/integration/runner-release-exit-paths-test.sh — ✗ [SPEC-5] cleanup dispatched with scope=release for: intake build
- tests/integration/sigterm-aborts-pipeline-test.sh (exceeded 480s, rc=124) — timed out before finishing

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-5] cleanup dispatched with scope=release for: intake build
    [2mno release from: intake build | marker= [0m
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.GgkwJX/tests/integration/runner-release-exit-paths-test.sh
integration: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.GgkwJX/tests/integration/sigterm-aborts-pipeline-test.sh (exceeded 480s, rc=124)
  [38;2;74;222;128m✓[0m [SPEC-6] the blocked hook does not outlive the run
  [38;2;0;212;255mSPEC-6b: a hook child that ignores TERM does not outlive the run[0m
  [38;2;74;222;128m✓[0m [SPEC-6b] a hook child that ignores TERM does not outlive the run
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 19 tests failed[0m
--- output below ran against a process being killed at its time bound;
--- any assertion failures in it are UNTRUSTWORTHY (#1613) ---
[38;2;0;212;255m[1m  sigterm-aborts-pipeline — kill -TERM halts pipeline (#686)[0m
[2m  ══════════════════════════════════════════[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
