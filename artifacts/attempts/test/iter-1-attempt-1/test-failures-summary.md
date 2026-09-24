# Test stage summary

- verdict: fail
- passed: 718
- failed: 11
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-8] pr_open_run returns 2 on 0-commit branch
    [2mexpected: 2, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-10] every manifest-declared verdict appears in ADR-019's table
    [2mabsent from ADR-019: blocked [0m
  [38;2;248;113;113m✗[0m [SPEC-5] real scripts/ core/ plugins/ tree is clean
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-4] PR still opened despite a high advisory finding
    [2mkey .status: expected opened, got: null[0m
  [38;2;248;113;113m✗[0m [SPEC-1] merge-result.json status==merged (gate pass + ready)
    [2mexpected: merged, got: [0m
  [38;2;248;113;113m✗[0m [SPEC-5] merge-result.json status==merged (gate pass + advisory)
  [38;2;248;113;113m✗[0m [SPEC-1] merge-result.json status==merged
  [38;2;248;113;113m✗[0m [SPEC-1] pr-result.json status==merged
  [38;2;248;113;113m✗[0m [SPEC-2] merge-result.json status==pr_fallback on gate fail
    [2mexpected: pr_fallback, got: [0m
  [38;2;248;113;113m✗[0m [SPEC-3] merge-result.json status==pr_fallback on gate absent
  [38;2;248;113;113m✗[0m [SPEC-8] merge-result.json status==pr_fallback on specification
  [38;2;248;113;113m✗[0m [SPEC-5] gate pass but review absent → status==pr_fallback (not merged)
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.IRoRgd/tests/unit/merge-v2-result-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.IRoRgd/tests/unit/pr-open-zero-commits-halts-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.IRoRgd/tests/unit/lint-verdict-classify-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.IRoRgd/tests/unit/lint-grep-c-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.IRoRgd/tests/unit/pr-open-advisory-review-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.IRoRgd/tests/integration/per-run-state-isolation-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.IRoRgd/tests/integration/merge-policy-auto-unless-flagged-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.IRoRgd/tests/integration/merge-policy-auto-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.IRoRgd/tests/integration/pr-pipeline-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.IRoRgd/plugins/tool/pr-open/tests/pr-open-test.sh
[2m  ══════════════════════════════════════════[0m
  [38;2;0;212;255mSPEC-1: manifest provides.result_contract==2 + role + valid_verdicts[0m
  [38;2;74;222;128m✓[0m [SPEC-1] merge manifest declares result_contract: 2
  [38;2;74;222;128m✓[0m [SPEC-1] merge manifest declares role: merge_executor
  [38;2;74;222;128m✓[0m [SPEC-1] merge manifest valid_verdicts contains pass
  [38;2;74;222;128m✓[0m [SPEC-1] merge manifest valid_verdicts contains error
  [38;2;74;222;128m✓[0m [SPEC-8] pr-result.json .reason cites no committed changes
  [38;2;74;222;128m✓[0m plugin.result verdict=error reason=no_committed_changes emitted
  [38;2;74;222;128m✓[0m gh pr create not reached (halt before push/gh)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 4 tests failed[0m
  [38;2;0;212;255m9. wiring — npm run lint and the CI Lint job[0m
  [38;2;74;222;128m✓[0m [wiring] package.json lint chain invokes the checker
  [38;2;74;222;128m✓[0m [wiring] CI Lint job invokes the checker
  [38;2;248;113;113m[1m1 of 28 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-4] package.json lint script includes lint-grep-c.sh
  [38;2;74;222;128m✓[0m [SPEC-5] .github/workflows/test.yml references lint-grep-c step
  [38;2;74;222;128m✓[0m [SPEC-6] .github/workflows/deferred-tracker.yml has if: failure() step
  [38;2;248;113;113m[1m1 of 16 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-7] overflow is collapsed into a details block
  [38;2;74;222;128m✓[0m [SPEC-7] details block is closed
  [38;2;74;222;128m✓[0m [SPEC-7] a blank line separates </details> from the next line
  [38;2;248;113;113m[1m1 of 27 tests failed[0m
[38;2;0;212;255m[1m  per-run state isolation (#887)[0m
  [38;2;74;222;128m✓[0m T1: run-aaa exits 0
  [38;2;74;222;128m✓[0m [SPEC-7] no merge-result.json for high finding + advisory
  [38;2;74;222;128m✓[0m [SPEC-7] gh pr merge NOT called for high-severity finding (advisory)
  [38;2;248;113;113m[1m2 of 28 tests failed[0m
  [38;2;248;113;113m✗[0m [SPEC-6] pr_open_run returns 2 on genuine push failure
  [38;2;74;222;128m✓[0m [SPEC-6] pr-result.json .reason surfaces the real push stderr
  [38;2;248;113;113m✗[0m pr-result.json pr_url is non-empty
  [38;2;248;113;113m✗[0m [SPEC-5] pr-result.json draft=false (non-draft default, _TPL_PR_DRAFT unset)
  [38;2;248;113;113m✗[0m pr-result.json branch=zbuild/issue-999
  [38;2;248;113;113m✗[0m [SPEC-6] _TPL_PR_DRAFT=true: pr-result.json draft=true
  [38;2;248;113;113m✗[0m existing PR: status=updated
  [38;2;248;113;113m✗[0m existing PR: pr_number=42
    _router="$(grep -c '^router:' "$MANIFEST" 2>/dev/null || echo 0)"
lint-grep-c: tests/unit/merge-v2-result-test.sh:62 — `grep -c … || echo` yields "0\n0" on no-match; use `|| true`
    _prim="$(grep -c 'primary: true' "$MANIFEST" 2>/dev/null || echo 0)"
lint-grep-c: tests/unit/merge-v2-result-test.sh:68 — `grep -c … || echo` yields "0\n0" on no-match; use `|| true`
    _cleanup="$(grep -c '^\s*cleanup:' "$MANIFEST" 2>/dev/null || echo 0)"
lint-grep-c: 9 occurrence(s). `grep -c` already prints the count — replace `|| echo 0` with `|| true`.
[38;2;248;113;113m[1m✗[0m pr_open: refusing to open PR — review verdict is 'block'
  [38;2;248;113;113m✗[0m blocked verdict returns rc=2
    [2mexpected exit code: 2, got: 1[0m
  [38;2;248;113;113m✗[0m pr-result.json status=blocked
    [2mexpected: blocked, got: null[0m
[38;2;248;113;113m[1m✗[0m pr_open: refusing to open PR — no review signal (neither review.json nor review-report.json; fail-closed per ADR-001)
  [38;2;248;113;113m✗[0m no review signal returns rc=2
  [38;2;248;113;113m✗[0m pr-result.json status=blocked when no review signal
  [38;2;248;113;113m✗[0m advisory mode: status=opened (not blocked on advisory review)
    [2mexpected: opened, got: null[0m
```
