# Acceptance checkpoint — issue #1806

## Files read
- requirements.json — 6 requirements R-1..R-6
- test-results.json — full test output; 7 failures from 842 tests; TEST VERDICT: fail

## Conclusions per requirement

**R-1 (per-emit cost materially reduced):** UNMET. fork-budget-test.sh fails: 5110 > 4500. The FORK_BUDGET was lowered to 4500 but actual measured fork count exceeds it. The before/after reduction is not demonstrated.

**R-2 (no malformed timestamps, regression test reddens):** MET. `_eb_host_is_mac()` uses $OSTYPE. SPEC-1 NEGCTL PASS — test fails on old code, passes on new. BSD date mock correctly exercises the darwin path even on Linux CI.

**R-3 (every stage event carries `stage`; redaction.applied attributed):** UNMET. Code adds `export ZBUILD_CURRENT_STAGE=run-status-comment` and sources event-bus; SPEC-5 tests pass. But `run-status-comment-render-test.sh` SPEC-8 fails ("no eb_emit_event in the sidecar — expected: 0, got: 1") — an existing test enforcing the opposite invariant was not updated.

**R-4 (watcher not re-woken by own events; no PATCH on unchanged body):** UNMET. SPEC-3 and SPEC-4 both fail their setup assertion ("first PATCH fired — no PATCH in GH_LOG"). Their meaningful assertions ("no spurious PATCH", "no PATCH when body identical") pass trivially because the first PATCH never fired — the test scenario was never established. The requirement is not demonstrated.

**R-5 (fork count pinned by test, lower than merge-base):** UNMET. fork-budget-test.sh fails: 5110 > 4500. The test pins the count but the code does not meet its own lowered budget.

**R-6 (event contents otherwise unchanged):** UNSURE. SPEC-2 is a tautology (acceptance-gate found it passes on old code). `test-plugin-result-write-fallback-test.sh` fails — test.result_write.fallback event not emitted (events.jsonl empty), suggesting an event emission regression introduced by the event-bus changes.

## Additional failures (not directly mapped to R-1..R-6)
- cli-status-comment-test.sh SPEC-3: --run does not PATCH persisted id (0 instead of 1)
- lint-grep-c: `grep -c '' … || echo 0` in run-status-comment-loop-test.sh:336 — lint violation introduced by new test

## What is still unresolved
- R-6: whether test.result_write.fallback failure is caused by the event-bus refactoring or an unrelated pre-existing condition; cannot determine without reading the test plugin's emit code vs. the new event-bus changes
