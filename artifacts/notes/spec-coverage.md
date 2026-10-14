# spec-coverage notes — round 2 (re-judgment)

## Key discovery

The prior round's notes misquote SPEC-2. The notes claim SPEC-2 says
"yields disposition misconfigured and the run does not reach the dispatch loop"
but the actual SPEC-2 text (from the ACCEPTANCE block) is:

> "_runner_resolve_run_limit_s resolves template max_run_s > ZBUILD_MAX_RUN_S > 20700;
> a non-integer or non-positive value in either source causes the runner to exit 1
> with a message naming the misconfigured source before any stage dispatch"

"exit 1 with a message" is NOT the same as "disposition=misconfigured in pipeline-state.json."

## Re-mapping — all requirements

**R-1**: SPEC-1 demands pipeline status timed_out in pipeline-state.json, pipeline.end carrying
the in-flight stage name and limit_s. Covers "stops and ends timed_out naming in-flight stage and
limit." COVERED.

**R-2**: SPEC-1 demands "watchdog fires even when the engine is idle between dispatches (not only
inside a stage)." Matches R-2 exactly. COVERED.

**R-3**: SPEC-1 demands "a stage that ignores SIGTERM is dead within TERM+10 s."
Worst-case child (TERM-ignoring) guaranteed dead subsumes the whole process group dying.
COVERED.

**R-4**: SPEC-1 demands "release and persist always_run stages both execute on the timed-out exit
path." Covers "release and persist still run." COVERED.

**R-5**: R-5 requires "a non-integer or non-positive value in either is refused as `misconfigured`."
In zBuild, `misconfigured` is an ADR-054 disposition written to pipeline-state.json.
SPEC-2 demands "exit 1 with a message naming the misconfigured source before any stage dispatch."
Demanding exit-1-with-message is a weaker condition than demanding disposition=misconfigured in
pipeline-state.json. An implementation that prints an error and exits 1 without writing
disposition=misconfigured to run state satisfies SPEC-2 but does not satisfy R-5.
SPEC-2 does not name the disposition, does not name pipeline-state.json, and does not require
the misconfigured ADR-054 lifecycle value to be recorded. GAP.

**R-6**: SPEC-3 demands "after waiting past max_run_s the status is still the stage-driven result,
proving the watchdog was reaped." This covers "no leftover process" by inference via timing.
A live but unfired watchdog would change state after max_run_s, so the observation that it does
not change implies reaping. The SPEC itself states the inference ("proving the watchdog was
reaped"). COVERED (spec-correspondence's concern is implementation quality, not SPEC scope).

**R-7**: SPEC-4 demands "a run resumed after a timed_out end is not stopped immediately — its
watchdog is armed from the resumed run's wall-clock start, not the original run's." Covers the
fresh-limit requirement. COVERED.

**R-8**: SPEC-5 demands no reference to GITHUB_ACTIONS, bare CI, TRAVIS, CIRCLECI, RUNNER_OS, or
BUILD_BUILDID in limit-resolution code. R-8 says "no branch on the platform, nothing read from
GitHub's job limit." The named variables cover all real-world CI platform identifiers. The
"no branch on the platform" intent is satisfied by prohibiting the concrete variable names.
COVERED.

**R-9**: SPEC-6 demands ADR-025 amended with ## Enforced by and ADR-054 §11 amended with ##
Enforced by. The issue's "§9" is a section-number label; the design places it at §11; the
substantive requirement (amendment + Enforced by) is covered. COVERED.

**R-10**: SPEC-6 demands "npm test and npm run lint pass." COVERED (whether they pass is a
build/test concern, not a SPEC-coverage gap).

## Conclusion

R-5 is NOT fully covered. SPEC-2 demands exit-1-with-message but not the `misconfigured`
disposition in pipeline-state.json, which R-5 explicitly requires ("refused as `misconfigured`").

VERDICT: uncovered
