# Acceptance checkpoint — issue #1752

## Files read
- test-results.json: 9 failures, verdict fail
- run-tests.sh (modified): removes _RT_KILL_GRACE, uses _acceptance_timeout_prefix + ZBUILD_NEGCTL_KILL_GRACE
- run-tests-timeout-report-test.sh line 123-124: greps for literal '"-k" "$_RT_KILL_GRACE"' — this string no longer exists in run-tests.sh after the PR removes _RT_KILL_GRACE
- acceptance-negctl-test.sh line 551-552: same grep pattern for _RT_KILL_GRACE
- mutation-relevance-test.sh: strips run-mutation.sh up to Main loop sentinel and saves to temp file; then sources it; SCRIPT_DIR resolves to temp dir; `source "$SCRIPT_DIR/lib/timeout-cmd.sh"` → No such file
- run-mutation-empty-dir-clean-gate-test.sh: copies run-mutation.sh to sandbox/scripts/ without copying lib/timeout-cmd.sh; run-mutation.sh fails to source it

## Conclusions

### Failures caused by this PR
1. **RT-K-STRUCT** (run-tests-timeout-report-test.sh + acceptance-negctl-test.sh): the tests grep for `"-k" "$_RT_KILL_GRACE"` in run-tests.sh. The PR removed `_RT_KILL_GRACE` and replaced with ZBUILD_NEGCTL_KILL_GRACE + _acceptance_timeout_prefix call. The grep returns 0 instead of 1.

2. **mutation-relevance-test.sh**: the test copies run-mutation.sh to a temp location. The new `source "$SCRIPT_DIR/lib/timeout-cmd.sh"` in run-mutation.sh resolves SCRIPT_DIR to the temp directory, where no lib/timeout-cmd.sh exists.

3. **run-mutation-{empty-dir, kill-grace, stale-anchor}**: all copy run-mutation.sh to a sandbox without copying lib/timeout-cmd.sh. Same failure mode.

4. **Lint SC2034**: `ZBUILD_NEGCTL_KILL_GRACE` assigned in run-tests.sh and run-mutation.sh but shellcheck cannot see its use inside the sourced function → SC2034 warning → shellcheck exits non-zero → lint fails.

### Failures likely pre-existing (not caused by PR)
5. security-lens-test.sh: awk tries to open `legacy/scripts/lib/compound-audit.sh` — legacy/ excluded from issue worktrees per ADR-059 §2
6. scope-manifest-b1-regression-test.sh SPEC-5: checks _extract_scope_from_design pruned from legacy — same legacy/ exclusion issue

## Verdict
VERDICT: fail
REASON: npm test fails with 7+ failures introduced by the PR (mutation harness can't find timeout-cmd.sh; structural tests grep for removed _RT_KILL_GRACE literal); npm run lint also fails (SC2034 for ZBUILD_NEGCTL_KILL_GRACE)
UNMET: R-6; R-3 (partially — mutation harness tests break from new source path)

## What would be next
Nothing — this is the final acceptance judgment.
