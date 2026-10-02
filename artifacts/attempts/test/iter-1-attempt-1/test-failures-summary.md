# Test stage summary

- verdict: fail
- passed: 782
- failed: 7
- exit_code: 1

## Failing files

- tests/integration/merge-policy-auto-test.sh — exited non-zero without a failing check, after its last passing check: gh pr merge NOT called under specification
- tests/integration/merge-policy-auto-unless-flagged-test.sh — exited non-zero without a failing check, after its last passing check: [SPEC-1] gh pr merge called when gate pass + merge_readiness=ready
- tests/integration/pr-pipeline-test.sh — exited non-zero without a failing check, after its last passing check: [#1844/SPEC-23] blocked summary: names review_signal_missing
- tests/unit/lint-disposition-words-test.sh — ✗ [SPEC-4] the shipped plugins/ tree passes — expected: 0, got: 1
- tests/unit/lint-verdict-words-test.sh — ✗ [W5] the real tree passes — expected: 0, got: 1
- tests/unit/stage-signal-test.sh — ✗ [G5] every plugin's signal handling uses the helper — expected: 0, got: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [W5] the real tree passes
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-4] the shipped plugins/ tree passes
  [38;2;248;113;113m✗[0m [G5] every plugin's signal handling uses the helper
  [38;2;248;113;113m✗[0m [G5] every literal unavailable names its service
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8pNMMT/tests/unit/lint-verdict-words-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8pNMMT/tests/unit/lint-disposition-words-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8pNMMT/tests/unit/stage-signal-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8pNMMT/tests/integration/merge-policy-auto-unless-flagged-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8pNMMT/tests/integration/merge-policy-auto-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.8pNMMT/tests/integration/pr-pipeline-test.sh
lint: FAIL (npm run lint)
lint-verdict-words: agent/pr-delivery/plugin.sh:116 writes verdict 'block', which agent/pr-delivery/manifest.yaml does not declare in valid_verdicts
lint-verdict-words: 1 literal verdict(s) not declared by their plugin's manifest (of 200 checked) — declare the word in config.valid_verdicts, use a declared one, or mark a non-own verdict '# verdict-ok: <why>'
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 12 tests failed[0m
  [38;2;0;212;255mSPEC-5: wiring[0m
  [38;2;74;222;128m✓[0m [SPEC-5] npm run lint runs it
  [38;2;74;222;128m✓[0m [SPEC-5] the CI Lint job runs it
  [38;2;248;113;113m[1m1 of 13 tests failed[0m
  [38;2;248;113;113m[1m2 of 11 tests failed[0m
  [38;2;0;212;255mSPEC-1: auto_unless_flagged + gate pass + merge_readiness=ready → merged[0m
  [38;2;74;222;128m✓[0m [SPEC-1] pr_stage_run exits 0 on auto-merge path (ready)
  [38;2;74;222;128m✓[0m [SPEC-1] merge-result.json written when gate+report both pass
  [38;2;74;222;128m✓[0m [SPEC-1] merge-result.json verdict==pass (gate pass + ready)
  [38;2;74;222;128m✓[0m [SPEC-1] gh pr merge called when gate pass + merge_readiness=ready
  [38;2;0;212;255mSPEC-2: auto_unless_flagged + gate pass + needs_attention → PR open[0m
  [38;2;74;222;128m✓[0m pr_stage_run exits 0 on specification PR fallback
  [38;2;74;222;128m✓[0m pr-url.txt written on specification fallback
  [38;2;74;222;128m✓[0m [SPEC-19] merge-result.json verdict==pass on specification fallback
  [38;2;74;222;128m✓[0m [SPEC-19] merge-result.json data.mode==pr_fallback on specification
  [38;2;74;222;128m✓[0m gh pr merge NOT called under specification
  [38;2;0;212;255mSPEC-4: merge_policy==auto_unless_flagged + review-report absent → opens draft PR (fail-closed)[0m
  [38;2;74;222;128m✓[0m [#1844/SPEC-22] pr-open blocked: verdict is error
  [38;2;74;222;128m✓[0m [#1844/SPEC-22] pr-open blocked: disposition is complete
  [38;2;74;222;128m✓[0m [#1844/SPEC-22] pr-open blocked: reason is review_signal_missing
  [38;2;74;222;128m✓[0m [#1844/SPEC-23] blocked summary: does NOT say 'pass — delivered … delegating to pr-open'
  [38;2;74;222;128m✓[0m [#1844/SPEC-23] blocked summary: names review_signal_missing
  [38;2;0;212;255mSPEC-6: pr-open surfaces push stderr in pr-result.json[0m
lint-llm-envelope: OK — 60 plugin source(s) checked, no markdown-document envelope fields
lint-verdict-classify: 34 manifest(s) checked, all declared verdicts classify
lint-disposition-classify: 1 manifest(s) checked, all declared failure classes classify
lint-silenced-redirect: clean
```
