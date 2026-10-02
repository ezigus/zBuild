# Test stage summary

- verdict: fail
- passed: 800
- failed: 4
- exit_code: 1

## Failing files

- tests/unit/lint-disposition-words-test.sh — ✗ [SPEC-4] the shipped plugins/ tree passes — expected: 0, got: 1
- tests/unit/lint-verdict-words-test.sh — ✗ [W5] the real tree passes — expected: 0, got: 1
- tests/unit/stage-signal-test.sh — ✗ [G5] every literal unavailable names its service — expected: 0, got: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [W5] the real tree passes
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-4] the shipped plugins/ tree passes
  [38;2;248;113;113m✗[0m [G5] every literal unavailable names its service
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Jkq2ak/tests/unit/lint-verdict-words-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Jkq2ak/tests/unit/lint-disposition-words-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Jkq2ak/tests/unit/stage-signal-test.sh
lint: FAIL (npm run lint)
lint-verdict-words: agent/pr-delivery/plugin.sh:273 writes verdict 'complete', which agent/pr-delivery/manifest.yaml does not declare in valid_verdicts
lint-verdict-words: agent/pr-delivery/plugin.sh:280 writes verdict 'unavailable', which agent/pr-delivery/manifest.yaml does not declare in valid_verdicts
lint-verdict-words: 7 literal verdict(s) not declared by their plugin's manifest (of 199 checked) — declare the word in config.valid_verdicts, use a declared one, or mark a non-own verdict '# verdict-ok: <why>'
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 12 tests failed[0m
  [38;2;0;212;255mSPEC-5: wiring[0m
  [38;2;74;222;128m✓[0m [SPEC-5] npm run lint runs it
  [38;2;74;222;128m✓[0m [SPEC-5] the CI Lint job runs it
  [38;2;248;113;113m[1m1 of 13 tests failed[0m
  [38;2;74;222;128m✓[0m [G5] every plugin's signal handling uses the helper
  [38;2;248;113;113m[1m1 of 11 tests failed[0m
lint-verdict-words: agent/pr-delivery/plugin.sh:123 writes verdict 'complete', which agent/pr-delivery/manifest.yaml does not declare in valid_verdicts
lint-verdict-words: agent/pr-delivery/plugin.sh:242 writes verdict 'complete', which agent/pr-delivery/manifest.yaml does not declare in valid_verdicts
lint-verdict-words: agent/pr-delivery/plugin.sh:253 writes verdict 'complete', which agent/pr-delivery/manifest.yaml does not declare in valid_verdicts
```
