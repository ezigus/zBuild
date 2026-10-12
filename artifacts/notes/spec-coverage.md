# spec-coverage notes

## Design read: complete

Design places `_runner_resolve_run_limit_s` in `scripts/lib/stage-limits.sh`, watchdog as inline
subshell in `runner.sh` `main()`, abort word `timed_out` added to `abort-propagation.sh`,
pipeline status `timed_out` wired through `_runner_end_on_abort` / `_runner_abort_trap`,
resume path amended in `core/state/resume.sh`, ADRs amended (ADR-054 §11, ADR-025, ADR-006, ADR-015).

## Mapping — R-1 through R-10

**R-1**: Ends timed_out naming in-flight stage and limit — SPEC-1 says pipeline status timed_out
in pipeline-state.json and pipeline.end event carrying status=timed_out, the in-flight stage, and
limit_s. Fully covered. "Reddens at merge-base" = verification-only requirement; excluded per
instructions.

**R-2**: Watchdog fires between stages — SPEC-1 "watchdog fires even when the engine is idle
between dispatches (not only inside a stage)". Design confirms watchdog is a separate background
subshell, not coupled to dispatch. Covered.

**R-3**: Whole process group dies, TERM-ignoring child gone after TERM + 10 s — SPEC-1 "a process
that ignores TERM is dead within TERM + 10 s". The worst-case (TERM-ignoring) child being
guaranteed dead subsumes the whole group. Covered.

**R-4**: release and persist still run — SPEC-1 "release and persist execute on every timed-out
exit path". Covered.

**R-5**: Precedence template > env > 20700, each layer tested; non-integer/non-positive refused as
misconfigured — SPEC-2 "_runner_resolve_run_limit_s resolves template max_run_s > ZBUILD_MAX_RUN_S
> 20700; a non-integer or non-positive value in template or env yields disposition misconfigured
and the run does not reach the dispatch loop". All three layers named, validation named, test file
run-limit-precedence-test.sh. Covered.

**R-6**: Run finishing inside limit untouched, watchdog gone after exit — SPEC-3 "a run that
finishes within max_run_s exits with its own pipeline status unchanged; the watchdog process does
not exist after the runner process exits". Covered.

**R-7**: Resumed run gets fresh limit — SPEC-4 "a run resumed after a timed_out end is not stopped
immediately — its watchdog is armed from the resumed run's wall-clock start, not the original
run's". Covered.

**R-8**: Same behaviour locally and in CI, no platform branch — SPEC-5 "the limit is resolved from
template, env, or constant only; scripts/lib/stage-limits.sh and core/pipeline/runner.sh contain
no reference to GITHUB_ACTIONS, CI, or any platform-specific variable in the new code". Covered.

**R-9**: ADR-054 §9 and ADR-025 amended with ## Enforced by — SPEC-6 covers ADR-025 ## Enforced by
+ ADR-054 new section (§11 in design, §9 in issue) with ## Enforced by. Section number is a design
detail; the requirement is that the ADR is amended with the described content and ## Enforced by
entries. Covered.

**R-10**: npm test + npm run lint green — SPEC-6 "npm test and npm run lint pass". Covered.

## Conclusion

All ten requirements are fully covered by SPEC-1 through SPEC-6. VERDICT: covered.
