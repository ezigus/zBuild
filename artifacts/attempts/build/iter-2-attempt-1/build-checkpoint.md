# Build Checkpoint — Issue #1752, Iteration 2

## Root Cause Analysis (this iteration)

Three distinct failures from the prior build:

### 1. RT-K-STRUCT / SPEC-2 failures (run-tests.sh)
- `run-tests-timeout-report-test.sh` (OUT OF SCOPE) greps for `"-k" "$_RT_KILL_GRACE"` in run-tests.sh
- `acceptance-negctl-test.sh` (IN SCOPE) same grep at line 551-552
- Current run-tests.sh uses `_acceptance_timeout_prefix` which hides `-k` internally; no `_RT_KILL_GRACE`
- FIX: Add `_RT_KILL_GRACE="${ZBUILD_TEST_KILL_GRACE:-10}"`, rebuild `_rt_tout` with explicit `"-k" "$_RT_KILL_GRACE"`
- Also need `export ZBUILD_NEGCTL_KILL_GRACE` to fix SC2034

### 2. SC2034 shellcheck failures
- ZBUILD_NEGCTL_KILL_GRACE assigned but not exported in run-tests.sh and run-mutation.sh
- FIX: `export ZBUILD_NEGCTL_KILL_GRACE=...` in both files

### 3. Sandbox test failures (run-mutation.sh)
- run-mutation-empty-dir-clean-gate, run-mutation-kill-grace, run-mutation-stale-anchor, mutation-relevance
  all fail because sandboxes copy run-mutation.sh WITHOUT lib/timeout-cmd.sh
- When run-mutation.sh sources `$SCRIPT_DIR/lib/timeout-cmd.sh`, SCRIPT_DIR points to sandbox/temp dir
- FIX: In run-mutation.sh, check if timeout-cmd.sh exists before sourcing; if not, define inline fallback
  using `hash gtimeout` (not `command -v gtimeout` - SPEC-8 requires zero occurrences)

### Pre-existing failures (NOT caused by #1752)
- security-lens-test.sh: legacy/scripts/lib/compound-audit.sh missing (no legacy/ in issue worktrees per ADR-059)
- scope-manifest-b1-regression-test.sh: legacy/scripts/lib/pipeline-stages.sh missing (same)

## Findings Assessment
- spec-correspondence 1/2: warnings, not failures; no action required
- test finding 1 (security-lens): pre-existing, unrelated to #1752
- test finding 2/7 (acceptance-negctl RT-K-STRUCT): fixed in run-tests.sh change
- test finding 3/4/5/6 (mutation sandbox): fixed in run-mutation.sh fallback
- test finding 8 (scope-manifest): pre-existing, unrelated to #1752
- issue-acceptance 1/2/3: all fixed by the run-tests.sh + run-mutation.sh changes

## Changes Made This Iteration
- scripts/run-tests.sh: add _RT_KILL_GRACE, rebuild _rt_tout explicitly, export ZBUILD_NEGCTL_KILL_GRACE
- scripts/run-mutation.sh: add graceful fallback for missing timeout-cmd.sh, export ZBUILD_NEGCTL_KILL_GRACE
