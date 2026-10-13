## spec-correspondence — partial

- judged 6 SPEC(s): 0 correspond, 6 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: P2 shows fast-one completed before the watchdog fired but does not establish the watchdog fired specifically during an idle inter-dispatch period (a concurrent slow second stage would also satisfy the assertion), and the "release and persist on every timed-out exit path" clause is checked only on P4's path — the other three timed-out paths carry no release/persist marker assertions.
- SPEC-2 partial: The end-to-end runner test for an invalid template value verifies rc=1 and that the dispatch loop was not reached, but does not check that pipeline-state.json carries disposition=misconfigured for that path, which the requirement equally requires for both invalid-env and invalid-template inputs.
- SPEC-3 partial: The absence of an abort sentinel proves the watchdog did not fire after the runner exited, but not that the watchdog process itself is dead — a still-running watchdog that has not yet fired also leaves the sentinel absent, so the requirement's explicit second clause ("the watchdog process does not exist") is not established.
- SPEC-4 partial: P4 establishes the watchdog is armed on resume (a disarmed watchdog would cause it to fail), and P3 establishes the run does not immediately time out, but the specific claim "armed from the resumed run's wall-clock start, not the original run's" is inferred from the combination and depends on test-scenario timing parameters that are not visible in the assertion code itself.
- SPEC-5 partial: The assertion checks a finite enumerated set of CI/CD platform variables (GITHUB_ACTIONS, CI, TRAVIS, CIRCLECI, RUNNER_OS, BUILD_BUILDID), but the requirement prohibits any platform-specific variable, a category with no fixed boundary, leaving unchecked the many other well-known CI environment variables that exist.
- SPEC-6 partial: The assertion verifies ADR document content, the baseline file, and two individual lint sub-scripts, but never executes the full `npm test` or `npm run lint` commands, which are explicitly named conditions in the requirement.

