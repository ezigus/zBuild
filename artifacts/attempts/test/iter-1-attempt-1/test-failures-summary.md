# Test stage summary

- verdict: fail
- passed: 829
- failed: 9
- exit_code: 1

## Failing files

- plugins/agent/security-lens/tests/security-lens-test.sh — exited non-zero without a failing check, after its last passing check: security-lens is discovered
- tests/unit/acceptance-negctl-test.sh — ✗ [SPEC-2] run-tests.sh _rt_tout wires -k for SIGKILL escalation — expected: 1, got: 0
- tests/unit/mutation-relevance-test.sh — /home/runner/work/_temp/zbuild-state/scratch/test/mutation-relevance.lX9lf7/harness-fns.sh: line 123: /home/runner/work/_temp/zbuild-state/scratch/test/mutation-relevance.lX9lf7/lib/timeout-cmd.sh: No such file or directory
- tests/unit/run-mutation-empty-dir-clean-gate-test.sh — ✗ [SPEC-1] dirty tree + empty dir → exit 0 — expected: 0, got: 1
- tests/unit/run-mutation-kill-grace-test.sh — ✗ [setup] ...and the tier scored that one mutant
- tests/unit/run-mutation-stale-anchor-test.sh — ✗ [SPEC-1] the gone-anchor spec gets its own STALE row
- tests/unit/run-tests-timeout-report-test.sh — ✗ RT-K-STRUCT: run-tests.sh _rt_tout wires -k for SIGKILL escalation — expected: 1, got: 0
- tests/unit/scope-manifest-b1-regression-test.sh — ✗ [SPEC-5] _extract_scope_from_design pruned from legacy/scripts/lib/pipeline-stages.sh — expected: 0, got: 

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-2] run-tests.sh _rt_tout wires -k for SIGKILL escalation
    [2mexpected: 1, got: 0[0m
  [38;2;74;222;128m✓[0m [SPEC-3] NC-V: ✗ outranks ✓ for the same SPEC → failed (0)
  [38;2;248;113;113m✗[0m [setup] ...and the tier scored that one mutant
    [2moutput missing: mutation: 1/1[0m
  [38;2;248;113;113m✗[0m [setup] the run lasted at least the 2s timeout
    [2monly 0s — the test never ran[0m
  [38;2;248;113;113m✗[0m [SPEC-1] dirty tree + empty dir → exit 0
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-1] dirty tree + empty dir → 'mutation: 0/0 passed'
    [2moutput missing: mutation: 0/0 passed[0m
  [38;2;248;113;113m✗[0m [SPEC-2] stderr contains 'refusing'
    [2moutput missing: refusing[0m
  [38;2;248;113;113m✗[0m [SPEC-2] stdout contains ABORTED line
    [2moutput missing: ABORTED[0m
  [38;2;248;113;113m✗[0m [SPEC-2] an ABORTED line was actually captured
    [2mnone found[0m
  [38;2;248;113;113m✗[0m [SPEC-3] clean tree + empty dir → exit 0
  [38;2;248;113;113m✗[0m [SPEC-3] clean tree + empty dir → 'mutation: 0/0 passed'
  [38;2;248;113;113m✗[0m SPEC_MUT counts toward n_specs (Phase A counts invalid specs too)
    [2mdenominator was 0: [0m
  [38;2;248;113;113m✗[0m [SPEC-1] the gone-anchor spec gets its own STALE row
    [2moutput missing: STALE gone.md[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.dqXwto/tests/unit/acceptance-negctl-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.dqXwto/tests/unit/run-mutation-kill-grace-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.dqXwto/tests/unit/run-mutation-empty-dir-clean-gate-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.dqXwto/tests/unit/run-mutation-stale-anchor-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.dqXwto/tests/unit/scope-manifest-b1-regression-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.dqXwto/tests/unit/run-tests-timeout-report-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.dqXwto/tests/unit/mutation-relevance-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.dqXwto/plugins/agent/security-lens/tests/security-lens-test.sh
lint: FAIL (npm run lint)
  [38;2;74;222;128m✓[0m [SPEC-3] NC-V: custom ZBUILD_ACCEPTANCE_RUN_CMD → inconclusive (2), file rc governs
  [38;2;74;222;128m✓[0m [SPEC-3] NC-V: tag present but unmarked → inconclusive (2), not a pass
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 41 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-1] the tier ends within the bound (0s)
  [38;2;74;222;128m✓[0m [SPEC-1] nothing of the mutant's test is left running
  [38;2;248;113;113m[1m2 of 5 tests failed[0m
  [38;2;248;113;113m✗[0m [SPEC-1] the summary surfaces stale specs on their own line
  [38;2;248;113;113m✗[0m [SPEC-1] the stale spec counts in the score (1/2, not 1/1)
  [38;2;248;113;113m✗[0m [SPEC-2] the racy patch really did fail once (marker written)
  [38;2;248;113;113m✗[0m [SPEC-2] contention does not fail the tier (exit 0)
  [38;2;248;113;113m✗[0m [SPEC-2] contention keeps its INFRA row
  [38;2;248;113;113m✗[0m [SPEC-2] contention stays out of the score
    [2mexpected: 0, got: [0m
  [38;2;74;222;128m✓[0m [SPEC-5] T5 simulation: scope_source stays plan when _extract_scope_from_design returns empty
  [38;2;74;222;128m✓[0m [SPEC-6] build copy of _extract_scope_from_design is byte-identical to design copy
  [38;2;248;113;113m[1m1 of 11 tests failed[0m
  [38;2;248;113;113m✗[0m [SPEC-5] _extract_scope_from_design pruned from legacy/scripts/lib/pipeline-stages.sh
  [38;2;248;113;113m✗[0m RT-K-STRUCT: run-tests.sh _rt_tout wires -k for SIGKILL escalation
  [38;2;74;222;128m✓[0m RT-K: SIGTERM-ignoring file escalated to SIGKILL via -k (rc=137 in TIMEOUT)
  [38;2;248;113;113m[1m1 of 13 tests failed[0m
/home/runner/work/_temp/zbuild-state/scratch/test/mutation-relevance.lX9lf7/harness-fns.sh: line 123: /home/runner/work/_temp/zbuild-state/scratch/test/mutation-relevance.lX9lf7/lib/timeout-cmd.sh: No such file or directory
[38;2;0;212;255m[1m  mutation harness relevance gate (#309)[0m
[2m  ══════════════════════════════════════════[0m
awk: fatal: cannot open file `/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.dqXwto/legacy/scripts/lib/compound-audit.sh' for reading: No such file or directory
[38;2;0;212;255m[1m  plugin: security-lens (first POC)[0m
  [38;2;74;222;128m✓[0m security-lens manifest validates (kind: agent + requires.core: [redaction, ...])
  [38;2;74;222;128m✓[0m security-lens is discovered
In scripts/run-tests.sh line 36:
  ^----------------------^ SC2034 (warning): ZBUILD_NEGCTL_KILL_GRACE appears unused. Verify use (or export if used externally).
In scripts/run-mutation.sh line 125:
    ^----------------------^ SC2034 (warning): ZBUILD_NEGCTL_KILL_GRACE appears unused. Verify use (or export if used externally).
  https://www.shellcheck.net/wiki/SC2034 -- ZBUILD_NEGCTL_KILL_GRACE appears ...
    ZBUILD_NEGCTL_KILL_GRACE="${ZBUILD_MUTATION_KILL_GRACE:-10}"
For more information:
  [38;2;74;222;128m✓[0m NC-B: tautological SPEC-2 → FAIL tautology
  [38;2;74;222;128m✓[0m NC-C: broken stub SPEC-3 → FAIL not_passing_at_head
  [38;2;74;222;128m✓[0m NC-D: #844-class tautology SPEC-4 → FAIL tautology
  [38;2;74;222;128m✓[0m [SPEC-2] non-bash runner: tautological py spec → NEGCTL FAIL SPEC-2 tautology
  [38;2;74;222;128m✓[0m [SPEC-2] NC-M: per-SPEC bound tautological file → NEGCTL FAIL SPEC-2 tautology
  [38;2;74;222;128m✓[0m [SPEC-2] _TEST_FAIL_MARKER_RE extracted from parse.sh (not a copy)
  [38;2;74;222;128m✓[0m [SPEC-2] extracted fail-marker regex is live (matches a real FAIL line)
  [38;2;248;113;113m✗[0m [SPEC-1] the STALE row names the missing anchor
  [38;2;74;222;128m✓[0m [SPEC-1] hung file reports TIMEOUT naming the bound, not FAIL
```
