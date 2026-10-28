## issue-acceptance — fail

- R-10 unmet — `sigterm-aborts-pipeline-test.sh` (an existing test for #686) times out at 480 s, most likely a regression from the new watchdog process not being reaped when the runner is externally SIGTERMed, and the shape-floor check flags two event-sequence golden files as potentially stale.

- NOT MET: R-10: npm test fails (sigterm-aborts-pipeline-test.sh 480 s timeout, likely watchdog-leak regression when runner is killed externally
- NOT MET: shape floor flags tests/golden/full-pipeline/event-sequence.golden and tests/golden/parity/event-sequence.golden as needing review)
- NOT SURE: R-1: the "reddens at merge-base" sub-claim — the regression test is new (absent at merge-base), so the claim holds only if reverting the runner implementation alone makes the test fail — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
- NOT SURE: the test output shows the test passes now but cannot confirm the red-on-revert direction without running against the old code — what would settle it: a test that fails when it is not met, or the code or document that shows it is met
