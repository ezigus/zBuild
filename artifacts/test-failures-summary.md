# Test stage summary

- verdict: fail
- passed: 714
- failed: 4
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m SPEC-4: tree-wide, zero cleanup hooks remain
    [2m/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.r58tsT/plugins/agent/security-lens/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [SPEC-3] zero per-stage cleanup hooks remain (ADR-062 §3)
    [2mstill declared by: /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.r58tsT/plugins/agent/security-lens/manifest.yaml[0m
  [38;2;248;113;113m✗[0m R1: stub is false after real LLM path
    [2mexpected: false, got: absent[0m
  [38;2;248;113;113m✗[0m [SPEC-3] router-fatal path writes v2 result (OUTPUT_R7 missing)
lint: FAIL (npm run lint)
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.r58tsT/tests/unit/teardown-purge-scratch-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.r58tsT/tests/integration/cleanup-release-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.r58tsT/plugins/agent/security-lens/tests/security-lens-test.sh
  [38;2;74;222;128m✓[0m SPEC-4: no plugin declares a cleanup hook any more
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 5 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-5] teardown_run returns rc=0 even when a cleanup hook returns non-zero
  [38;2;0;212;255mSPEC-6: teardown_run never dispatches scope=purge[0m
  [38;2;74;222;128m✓[0m [SPEC-6] teardown_run never dispatches scope=purge (only release)
  [38;2;248;113;113m[1m1 of 12 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-5] security-lens redacted_content ANSI bytes stripped before LLM prompt
  [38;2;74;222;128m✓[0m [SPEC-6] security-lens redacted_content genuine content survives sanitize
  [38;2;74;222;128m✓[0m [SPEC-10] postamble recovery → rc=0
  [38;2;74;222;128m✓[0m [SPEC-10] postamble recovery → findings.json written
  [38;2;74;222;128m✓[0m [SPEC-10] postamble recovery → recovered findings (1 finding, not empty)
In plugins/agent/security-lens/tests/security-lens-test.sh line 132:
    ^----------^ SC2034 (warning): run_complete appears unused. Verify use (or export if used externally).
  https://www.shellcheck.net/wiki/SC2034 -- run_complete appears unused. Veri...
lint-model-names: OK — no hardcoded model names in core/ plugins/ scripts/
    run_complete=$(grep -c '"plugin.result"' "$ZBUILD_EVENTS_JSONL" || true)
For more information:
```
