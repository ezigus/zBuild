# Test stage summary

- verdict: fail
- passed: 736
- failed: 2
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-6] every shipped manifest with a primary output is compliant
    [2m✗ plugins/tool/pr-open/manifest.yaml: declares verdict 'blocked', which verdict_classify does not classify
    add it to core/pipeline/verdict.sh (pass | warn | fail) or correct the manifest.
  [38;2;248;113;113m✗[0m [SPEC-10] every manifest-declared verdict appears in ADR-019's table
    [2mabsent from ADR-019: blocked [0m
✗ plugins/tool/pr-open/manifest.yaml: declares verdict 'blocked', which verdict_classify does not classify
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.iZADjS/tests/unit/lint-verdict-classify-test.sh
lint: FAIL (npm run lint)
  [38;2;74;222;128m✓[0m [wiring] package.json lint chain invokes the checker
  [38;2;74;222;128m✓[0m [wiring] CI Lint job invokes the checker
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m2 of 28 tests failed[0m
lint-grep-c: OK — no grep -c || echo occurrences in scripts/ core/ plugins/ tests/
lint-test-identity: OK — no real issue number used as test identity
lint-llm-envelope: OK — 56 plugin source(s) checked, no markdown-document envelope fields
lint-verdict-classify: 1 violation(s) across 33 manifest(s)
```
