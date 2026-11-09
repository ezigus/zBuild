# Test stage summary

- 1 test(s) failed
- verdict: fail
- passed: 191
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
unit: FAIL tests/integration/from-stage-rehydrate-test.sh
    [2mexpected >0, got: 0[0m
  [38;2;74;222;128m✓[0m [#1805/DSFSTG-3] no stage.skip emitted for verify (stage after --from-stage target must be dispatched, not skipped, in combined --resume --from-stage mode)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m2 of 29 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/DSFSTG-3] cycle.start emitted for cyc (--from-stage target dispatched in combined --resume --from-stage mode)
  [38;2;248;113;113m✗[0m [#1805/DSFSTG-3] stage.start emitted for verify despite verify=complete in interrupted state (Gap 11 fix: resume_mode=false clears skip guard after --from-stage target reached; fails on old code where verify is skipped)
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — DSFSTG-3: its test does not pass on the new code — the code or the test is wrong
