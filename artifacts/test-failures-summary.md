# Test stage summary

- verdict: fail
- passed: 829
- failed: 1
- exit_code: 1

## Failing files

- tests/unit/runner-map-parallel-stage-envelope-test.sh — ✗ [SPEC-8] map: dispatch arm writes stage_statuses[id]=complete

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-8] map: dispatch arm writes stage_statuses[id]=complete
    [2moutput missing: _update_stage_status[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.gfLPCs/tests/unit/runner-map-parallel-stage-envelope-test.sh
  [38;2;74;222;128m✓[0m B3: stage_statuses includes intake (covers all dispatch unit types)
  [38;2;74;222;128m✓[0m B3: stage_statuses includes review_lenses (covers all dispatch unit types)
  [38;2;74;222;128m✓[0m B3: stage_statuses includes feature_work (covers all dispatch unit types)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 16 tests failed[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — core/pipeline/runner.sh was put back to its old version and every test still passed, so it is not what runs the new behaviour — name the file whose code calls it, or write WIRING: none
