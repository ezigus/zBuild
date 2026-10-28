# Test stage summary

- verdict: fail
- passed: 820
- failed: 1
- exit_code: 1

## Failing files

- tests/integration/sigterm-aborts-pipeline-test.sh (exceeded 480s, rc=124) — timed out before finishing

## Failing lines (extracted)

```
integration: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Pf3EXq/tests/integration/sigterm-aborts-pipeline-test.sh (exceeded 480s, rc=124)
--- output below ran against a process being killed at its time bound;
--- any assertion failures in it are UNTRUSTWORTHY (#1613) ---
[38;2;0;212;255m[1m  sigterm-aborts-pipeline — kill -TERM halts pipeline (#686)[0m
[2m  ══════════════════════════════════════════[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
