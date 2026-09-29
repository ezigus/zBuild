# Test stage summary

- verdict: fail
- passed: 758
- failed: 2
- exit_code: 1

## Failing files

- plugins/agent/intake/tests/intake-test.sh — ✗ intake manifest outputs[0].path contains scope-manifest.md

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m intake manifest outputs[0].path contains scope-manifest.md
    [2moutput missing: scope-manifest.md[0m
  [38;2;248;113;113m✗[0m artifact filename list matches golden snapshot
    [2mgolden mismatch (run UPDATE_GOLDEN=1 to regenerate)[0m
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Hqic3N/plugins/agent/intake/tests/intake-test.sh
  [38;2;74;222;128m✓[0m [#1837/SPEC-13] manifest provides.events has >= 17 intake.* events (found: 17)
  [38;2;74;222;128m✓[0m [#1837/SPEC-14] template value wins over manifest config.router.timeout_s
  [38;2;74;222;128m✓[0m [#1837/SPEC-17] plugin.sh has no hardcoded artifact input path constructions
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 107 tests failed[0m
e2e: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Hqic3N/tests/e2e/parity-local-vs-ci-test.sh
```
