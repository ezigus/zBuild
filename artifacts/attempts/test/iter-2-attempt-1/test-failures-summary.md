# Test stage summary

- verdict: fail
- passed: 5
- failed: 2
- exit_code: 1

## Failing lines (extracted)

```
unit: FAIL tests/integration/merge-policy-auto-test.sh
unit: FAIL tests/integration/pr-pipeline-test.sh
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
```
