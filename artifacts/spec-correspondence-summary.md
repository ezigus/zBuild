## spec-correspondence — partial

- judged 6 SPEC(s): 0 correspond, 6 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The P2 idle-watchdog check always calls `assert_pass` in both branches of its conditional (whether or not the stage completed), so the sub-requirement that the watchdog fires specifically when the engine is idle between dispatches is never falsifiable; additionally, P4 verifies only that the *release* stage ran on the timed-out exit path while the requirement names *both* release and persist.
- SPEC-2 partial: The end-to-end runner behavior — disposition=misconfigured and dispatch loop not reached — is exercised only for an invalid `ZBUILD_MAX_RUN_S` env value; the requirement equally demands that behavior for a non-integer or non-positive *template* value, which is covered at the function-unit level (rc=1) but not at the full-runner level.
- SPEC-3 partial: The assertion confirms the runner exits 0 and the pipeline status is not timed_out, but contains no check that the watchdog process itself no longer exists after the runner exits, which is the second explicit clause of the requirement.
- SPEC-4 partial: The assertion verifies the resumed run does not end with timed_out status, but it cannot distinguish between "watchdog armed from the resumed run's wall-clock start" and "watchdog not armed at all on resume"; a completely disarmed watchdog would also make the assertion pass, leaving the mechanism stated in the requirement unestablished.
- SPEC-5 partial: The assertion checks only `GITHUB_ACTIONS` and bare `$CI`, but the requirement prohibits *any* platform-specific variable; other common CI environment variables (e.g., TRAVIS, CIRCLECI, RUNNER_OS, BUILD_BUILDID) are not checked, and `runner.sh` is not searched for `$CI` at all.
- SPEC-6 partial: The assertion checks ADR content and the baseline file but contains no check that `npm test` and `npm run lint` pass, which the requirement explicitly includes as a condition.

