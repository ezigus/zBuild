## issue-acceptance — fail

- The test suite fails on the new code — fork-budget-test reports 5110 > 4500 (R-1, R-5), SPEC-3/SPEC-4 sidecar loop tests never establish their setup PATCH so their "no spurious PATCH" assertions pass vacuously (R-4), and an existing test (run-status-comment-render-test.sh SPEC-8) fails because the change adds event-bus sourcing to the sidecar without updating the test that asserts it is absent (R-3).

- NOT MET: R-1: fork-budget-test.sh fails (5110 > 4500), per-emit cost reduction not demonstrated
- NOT MET: R-3: run-status-comment-render-test.sh SPEC-8 fails — existing test asserting no eb_emit_event in sidecar was not updated to accommodate the new attribution behavior
- NOT MET: R-4: SPEC-3/SPEC-4 setup assertion ("first PATCH fired") fails, leaving "no spurious second PATCH" assertions vacuously true — the no-rewake behavior is not verified
- NOT MET: R-5: fork-budget-test.sh fails (5110 > 4500), fork count is not pinned below merge-base
- NOT SURE: R-6: SPEC-2 is a tautology (passes on the old code, per acceptance-gate) — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: test.result_write.fallback event is no longer emitted in test-plugin-result-write-fallback-test.sh (events.jsonl empty), suggesting a possible event-emission regression from the event-bus changes — cannot confirm contents are unchanged — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
