# Test stage summary

- verdict: fail
- passed: 184
- failed: 2
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-5] _extract_scope_from_design pruned from legacy/scripts/lib/pipeline-stages.sh
    [2mexpected: 0, got: [0m
unit: FAIL plugins/agent/security-lens/tests/security-lens-test.sh
unit: FAIL tests/unit/scope-manifest-b1-regression-test.sh
awk: fatal: cannot open file `/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Pl6MVw/legacy/scripts/lib/compound-audit.sh' for reading: No such file or directory
[38;2;0;212;255m[1m  plugin: security-lens (first POC)[0m
[2m  ══════════════════════════════════════════[0m
  [38;2;74;222;128m✓[0m security-lens manifest validates (kind: agent + requires.core: [redaction, ...])
  [38;2;74;222;128m✓[0m security-lens is discovered
  [38;2;74;222;128m✓[0m [SPEC-5] T5 simulation: scope_source stays plan when _extract_scope_from_design returns empty
  [38;2;74;222;128m✓[0m [SPEC-6] build copy of _extract_scope_from_design is byte-identical to design copy
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 11 tests failed[0m
```
