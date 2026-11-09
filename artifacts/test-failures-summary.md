# Test stage summary

- failed: tests/integration/pipeline-resume-test.sh
- verdict: fail
- passed: 887
- failed: 1
- exit_code: 1

## Failing files

- tests/integration/pipeline-resume-test.sh — ✗ --from-stage without --resume exits 1 — expected: 1, got: 0 (and 3 more failing checks in this file)

## Failing lines (extracted)

```
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.43ehBV/tests/integration/pipeline-resume-test.sh
  [38;2;248;113;113m✗[0m --from-stage without --resume says it needs --resume
    [2moutput missing: only valid with --resume[0m
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m2 of 23 tests failed[0m
  [38;2;248;113;113m✗[0m --from-stage without --resume exits 1
    [2mexpected: 1, got: 0[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — DSFSTG-3: no assertion in the test files carries its tag — add one labelled with it; DSFSTG-3 (the file stopped after DSFSTG-1): its test never ran on the code from before this change — an earlier step in its test file stops the file there, so it is not shown to fail on the old code
