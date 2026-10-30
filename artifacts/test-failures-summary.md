# Test stage summary

- verdict: fail
- passed: 827
- failed: 3
- exit_code: 1

## Failing files

- plugins/agent/security-lens/tests/security-lens-test.sh — ✗ [SPEC-16] manifest provides.events contains plugin.result
- tests/unit/event-schema-emitted-coverage-test.sh — ✗ [#1951/SPEC-1] event-schema.json has 'plugin.run.start' in a plugin-owned namespace
- tests/unit/merge-v2-result-test.sh — ✗ [SPEC-1] manifest provides.events includes plugin.result

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.run.start' in a plugin-owned namespace
    [2mnamespace 'plugin' is declared by a plugin manifest; remove this entry from config/event-schema.json (ADR-001 §"Declared events")[0m
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.run.complete' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.result' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.run.error' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.cleanup.start' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.cleanup.complete' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.cleanup.error' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.cleanup.absent' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.run.refused' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.error' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.contract.violated' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.artifact.missing' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.artifact.empty' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.run.artifact_check_failed' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.run.artifact_check_skipped' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-1] event-schema.json has 'plugin.tamper.detected' in a plugin-owned namespace
  [38;2;248;113;113m✗[0m [#1951/SPEC-2] plugin declares engine-namespace event: plugins/tool/pr-open → plugin.pr_open.branch_fallback_used
    [2mengine namespaces (pipeline, stage, plugin, cycle, ...) are owned by the engine; remove this from the plugin's provides.events (ADR-001 §"Declared events")[0m
  [38;2;248;113;113m✗[0m [#1951/SPEC-2] plugin declares engine-namespace event: plugins/tool/pr-open → plugin.pr_open.preflight_remote_has_work
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.bcQM3j/tests/unit/event-schema-emitted-coverage-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.bcQM3j/tests/unit/merge-v2-result-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.bcQM3j/plugins/agent/security-lens/tests/security-lens-test.sh
  [38;2;74;222;128m✓[0m [SPEC-30] push failure → unavailable
  [38;2;74;222;128m✓[0m [SPEC-30] gh pr create failure → unavailable
  [38;2;74;222;128m✓[0m [SPEC-30] gh pr merge failure → unavailable
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 55 tests failed[0m
  [38;2;248;113;113m✗[0m [SPEC-1] manifest provides.events includes plugin.result
  [38;2;248;113;113m✗[0m [SPEC-19] canary: all preceding assertions passed (FAIL==0)
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m[1m2 of 94 tests failed[0m
  [38;2;248;113;113m✗[0m [SPEC-16] manifest provides.events contains plugin.result
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — SPEC-1/SPEC-2/tests/unit/event-schema-emitted-coverage-test.sh: its test does not pass on the new code — the code or the test is wrong
