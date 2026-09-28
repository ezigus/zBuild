# Test stage summary

- verdict: fail
- passed: 752
- failed: 3
- exit_code: 1

## Failing files

- plugins/agent/intake/tests/intake-test.sh — ✗ [#1837/SPEC-8] scope-manifest.md matches v1 baseline fixture
- tests/unit/artifact-type-retirement-test.sh — ✗ [SPEC-1] intake result filename is scope-manifest.md (not a bracketed list) — expected: scope-manifest.md, got: intake-result.json

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-1] intake result filename is scope-manifest.md (not a bracketed list)
    [2mexpected: scope-manifest.md, got: intake-result.json[0m
  [38;2;248;113;113m✗[0m [#1837/SPEC-8] scope-manifest.md matches v1 baseline fixture
integration: 252/253 passed
  [38;2;248;113;113m✗[0m artifact filename list matches golden snapshot
    [2mgolden mismatch (run UPDATE_GOLDEN=1 to regenerate)[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.T0dUQB/tests/unit/artifact-type-retirement-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.T0dUQB/plugins/agent/intake/tests/intake-test.sh
  [38;2;74;222;128m✓[0m [SPEC-6] provides.artifact_type removed from the allowed-keys list
  [38;2;74;222;128m✓[0m [SPEC-6] a manifest still carrying provides.artifact_type validates
  [38;2;74;222;128m✓[0m [SPEC-6] the key is present in the file, so the assertion is not vacuous
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 9 tests failed[0m
  [38;2;74;222;128m✓[0m valid platform ok-platform written
  [38;2;74;222;128m✓[0m path traversal filtered from scope-manifest
  [38;2;74;222;128m✓[0m generic fallback run returns rc=0
  [38;2;74;222;128m✓[0m generic fallback writes + ./
  [golden] MISSING: /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.T0dUQB/tests/golden/intake-scope-manifest-v1.golden (run with UPDATE_GOLDEN=1 to create)
e2e: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.T0dUQB/tests/e2e/parity-local-vs-ci-test.sh
```
