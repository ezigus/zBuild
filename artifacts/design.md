# Design: Run-level wall-clock limit with watchdog (#1944)

## Architectural Decision Summary

**Goal.** Add an engine-enforced per-run wall-clock limit so a hung pipeline is always killed,
its process group reaped, its always-run stages (release, persist) still executed, and the run
left in a resumable `timed_out` state.

**Context.** The engine has per-stage `router.timeout_s` knobs but no total-run ceiling. A run
that deadlocks between dispatches, or whose stages each finish under their individual budgets but
take too long collectively, can run indefinitely. CI job limits are platform-specific; the engine
must enforce its own.

**Decision.**

1. **Limit resolution** (`_runner_resolve_run_limit_s` in `scripts/lib/stage-limits.sh`,
   following the existing `_route_resolve_knob` pattern): template `max_run_s` >
   `ZBUILD_MAX_RUN_S` > 20700 s default. A non-integer or non-positive value in either source
   is refused with `misconfigured` disposition (rc 1) before any stage runs. Result stored in
   `_RUNNER_MAX_RUN_S`.

2. **Template accessor** (`template_max_run_s` in `core/pipeline/template.sh`): reads the
   top-level `max_run_s:` key lazily from `_TPL_SOURCE_FILE`, following the same pattern as
   `template_stage_negctl_timeout`. Returns empty when absent.

3. **Watchdog**: a background subshell armed in `main()` after the traps are installed and the
   resume sentinel is disarmed. The subshell captures `_RUNNER_RUN_PGID` (runner's PGID, read
   before backgrounding), sleeps `$_RUNNER_MAX_RUN_S`, writes `timed_out` to the abort sentinel
   (`_zbuild_arm_abort_sentinel timed_out`), then sends `TERM` to the runner's whole process group
   (`kill -TERM -- "-$_RUNNER_RUN_PGID"`) and escalates to `KILL` after a 10-second grace.
   `zbuild_pg_kill` (proc-group.sh) is NOT used here — it refuses its own group, and the watchdog
   IS in the runner's PG. Raw `kill` commands are used instead. The watchdog is reaped by its own
   KILL; the EXIT trap kills it on clean exit (`kill "$_RUNNER_WATCHDOG_PID" 2>/dev/null || true`).

4. **Abort word**: `timed_out` is added to the word vocabulary in `scripts/lib/abort-propagation.sh`
   comment. ADR-025 first-wins semantics preserve `timed_out` when the runner's SIGTERM trap
   subsequently calls `_zbuild_arm_abort_sentinel "sigterm"` — a no-op since a word is already
   recorded. The signal trap is amended to read `_RUNNER_ABORT_REASON` from `_zbuild_abort_reason`
   AFTER arming (not from the signal word), so `_RUNNER_ABORT_REASON` carries `timed_out` when
   the watchdog wrote it first.

5. **Pipeline status**: `timed_out` is a new pipeline-end status. `_runner_end_on_abort` gains a
   `timed_out` case (sets pipeline status `timed_out`, emits `pipeline.end status=timed_out` with
   `limit_s` and the in-flight stage). `_runner_abort_trap` gains a parallel `timed_out` branch
   (for the case where the sentinel is not checked at a dispatch boundary). `_pipeline_status_glyph`
   and `_pipeline_status_color` add `timed_out → fail` (✗, red). `_runner_render_open_items` adds
   `timed_out` to its rendering gate. `run_end_words` in `scripts/lib/run-open-items.sh` adds a
   `timed_out)` case with an appropriate human-readable message. Two new golden files are generated.

6. **Resume**: `get_resume_recommendation` in `core/state/resume.sh` is extended with
   `timed_out → manual_resume_only` (mirrors `aborted`). `main()` resolves and arms the watchdog
   on every invocation including `--resume`, so a resumed run gets a fresh limit.

7. **ADR and doc impact**:
   - ADR-025 gains `timed_out` in the word list and an extended `## Enforced by`.
   - ADR-054 gains a new §11 (run-level limit knob, precedence, validation) with `## Enforced by`.
   - `ADR-054-stage-contract.md` is removed from `config/adr-enforcement-baseline.txt`.
   - ADR-006 pipeline status enum table (lines 140–149) gains a `timed_out` row.
   - ADR-015 pipeline status → glyph/color table (lines 819–823) gains a `timed_out` row.

**Why not a new `run-watchdog.sh`?** The plan's step-5 explicitly places
`_runner_resolve_run_limit_s` in the existing `scripts/lib/stage-limits.sh` (where all limit
resolution functions live). The watchdog itself is ~15 lines of inline subshell in `runner.sh`,
not large enough to warrant a separate file.

**Why `timed_out` not `run_timed_out`?** ADR-054 §6a already defines `timed_out` as a valid
disposition word at the stage level. Reusing it at the pipeline level is consistent and saves
adding a new word to every closed-set enumeration that would otherwise remain correct.

**ADR-006 and ADR-015 added to scope (not in seed):** Both docs carry exhaustive tables of the
pipeline status enum. ADR-006 lines 140–149 enumerate `in_progress`, `complete`, `interrupted`,
`aborted`, `failed`, `preflight_failed` — wrong by omission when `timed_out` is added. ADR-015
lines 819–823 enumerate the same set mapped to glyphs and colors — wrong by the same omission.

```scope
config/adr-enforcement-baseline.txt
core/pipeline/runner.sh
core/pipeline/template.sh
core/state/resume.sh
docs/adr/ADR-006-resume-contract.md
docs/adr/ADR-015-stage-io-capture.md
docs/adr/ADR-025-abort-propagation.md
docs/adr/ADR-054-stage-contract.md
scripts/lib/abort-propagation.sh
scripts/lib/run-open-items.sh
scripts/lib/stage-limits.sh
tests/golden/pipeline-end/timed_out-w80.colored.txt
tests/golden/pipeline-end/timed_out-w80.layout.txt
tests/integration/resume-after-run-timeout-test.sh
tests/integration/run-timed-out-test.sh
tests/unit/abort-propagation-test.sh
tests/unit/run-limit-precedence-test.sh
tests/unit/run-open-items-test.sh
tests/unit/run-watchdog-clean-exit-test.sh
tests/unit/runner-pipeline-end-test.sh
```

```acceptance
SPEC-1[code]: a run whose wall-clock time exceeds max_run_s ends with pipeline status timed_out in pipeline-state.json and pipeline.end event carrying status=timed_out, the in-flight stage, and limit_s; the watchdog fires even when the engine is idle between dispatches (not only inside a stage); a process that ignores TERM is dead within TERM + 10 s; release and persist execute on every timed-out exit path covers: R-1 R-2 R-3 R-4
SPEC-2[code]: _runner_resolve_run_limit_s resolves template max_run_s > ZBUILD_MAX_RUN_S > 20700; a non-integer or non-positive value in template or env yields disposition misconfigured and the run does not reach the dispatch loop covers: R-5
SPEC-3[code]: a run that finishes within max_run_s exits with its own pipeline status unchanged; the watchdog process does not exist after the runner process exits covers: R-6
SPEC-4[code]: a run resumed after a timed_out end is not stopped immediately — its watchdog is armed from the resumed run's wall-clock start, not the original run's covers: R-7
SPEC-5[no-code]: the limit is resolved from template, env, or constant only; scripts/lib/stage-limits.sh and core/pipeline/runner.sh contain no reference to GITHUB_ACTIONS, CI, or any platform-specific variable in the new code covers: R-8
SPEC-6[no-code]: ADR-025 names timed_out in its word vocabulary with ## Enforced by entries citing the new tests; ADR-054 gains a §11 for the run-level limit with ## Enforced by; config/adr-enforcement-baseline.txt no longer lists ADR-054-stage-contract.md; npm test and npm run lint pass covers: R-9 R-10
WIRING:
core/pipeline/runner.sh
core/pipeline/template.sh
TESTFILES:
SPEC-1: tests/integration/run-timed-out-test.sh
SPEC-2: tests/unit/run-limit-precedence-test.sh
SPEC-3: tests/unit/run-watchdog-clean-exit-test.sh
SPEC-4: tests/integration/resume-after-run-timeout-test.sh
SPEC-5: tests/unit/run-limit-precedence-test.sh
SPEC-6: tests/unit/run-limit-precedence-test.sh
```

```supersedes
tests/unit/run-open-items-test.sh [O9]: asserts the runner contains exactly 5 loop-ending error lines using run_end_words; the new timed_out arm in _runner_end_on_abort adds a sixth matching line — the count assertion changes from "5" to "6"
```

LOOP_COMPLETE
