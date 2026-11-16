# Test stage summary

- failed: tests/unit/event-schema-emitted-coverage-test.sh
- verdict: fail
- passed: 908
- failed: 1
- exit_code: 1

## Failing files

- tests/unit/event-schema-emitted-coverage-test.sh — ✗ emitted type 'pipeline.refused.claimed' is in the composed known set — not in config/event-schema.json nor any manifest's provides.events (and 1 more failing check in this file)

## Failing lines (extracted)

```
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.yisxBz/tests/unit/event-schema-emitted-coverage-test.sh
  [38;2;74;222;128m✓[0m [#1951/R1] … and an engine namespace is not flagged
  [38;2;74;222;128m✓[0m [#1951/SPEC-4] a test file that is missing is not taken as clean
  [38;2;74;222;128m✓[0m [#1951/SPEC-6] the hardcoded plugin-namespace guard variable is absent from this file
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 23 tests failed[0m
  [38;2;248;113;113m✗[0m emitted type 'pipeline.refused.claimed' is in the composed known set
```

## The checks of this run
- the shape floor failed: missing_floor_files
