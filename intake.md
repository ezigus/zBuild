[bug] a run has no upper bound on its lifetime — 8 spinning processes held 8 of 10 cores for 32h and nothing reaped them

> **Rewritten 2026-10-09** after a design decision (previous bodies kept in the issue history). Line numbers are deliberately not used — code is named by file and function.

Part of #1659 (engine-enforced execution bounds — layer 2, per run), under #1795 (Phase 2).

**Classification: BUG — a run has no upper bound on its lifetime.**

## Problem

zBuild has no limit on how long a run lasts. On the operator's machine, 8 runner processes spun for **~32 hours** on 8 of 10 cores (load average 21) from a session that had long ended; killing them by hand took the load to 9.76.

- `always_run: [release]` (#1831) never fired — it runs from the runner's EXIT trap, and these runners never exited.
- A host admission cap (#1932) would not have helped — they were already admitted.
- `zbuild_run_is_live` (`core/state/resume.sh`) reads a spinning run as live forever, and `_cleanup_scan_state_dirs` (`scripts/lib/cleanup.sh`) skips `in_progress` folders, so nothing reclaims them either.
- #1801 bounds each **stage** dispatch, not the run.

In GitHub Actions the job is cut at 360 minutes because `zbuild-pipeline.yml` sets no `timeout-minutes`. That limit protects GitHub, not zBuild: it is not part of the engine, does not apply to local runs, and ends the job without the run saying why.

## Decision (2026-10-09)

1. **Every run has a wall-clock limit, enforced by the engine, the same locally and in CI.** Default **5 h 45 min (20700 s)** — under GitHub's 6 h job limit, so the engine ends the run itself, with a reason, before GitHub cuts it. zBuild obeys the GitHub limit; it does not read or depend on it.
2. **Overrides, in the same layering as #1801's stage limit:** template run-level **`max_run_s`** > **`ZBUILD_MAX_RUN_S`** > engine default. The environment variable changes the limit for one run without editing the template. The template loader rejects a non-integer or non-positive `max_run_s`; an invalid `ZBUILD_MAX_RUN_S` is refused the same way (`misconfigured`), never silently ignored.
3. **The runner arms a watchdog when the run starts and disarms it in its exit trap.** The watchdog is a separate process, so it fires even when the engine itself is spinning between stages.
4. **On expiry the run is stopped through the existing abort path** (ADR-025): the run's process group is killed through `zbuild_pg_kill` (TERM → KILL after 10 s, as #1801 decides), the run ends with the existing `timed_out` disposition (ADR-054 §6a) naming the in-flight stage and the limit, and the `always_run` stages (`release`, `persist`) still run.

5. **A resumed run gets a fresh limit.** A resume is a new runner process (and, in CI, a new job), so its watchdog starts from zero.

**Not in scope:** judging liveness by progress (#1801's per-stage limit already bounds a stage that makes no progress); an operator reaper for processes that escape a run's process group (#146).

**Order:** after #1932 and #1801 — all three edit `runner.sh` `main()` and the exit trap, and this reuses #1801's `zbuild_pg_kill` path.

## ADR

- **ADR-054 §9 — amended:** adds run-level `max_run_s`, `ZBUILD_MAX_RUN_S`, their precedence, the default (20700 s), and the validation rule.
- **ADR-025 — amended:** a run that reaches its limit ends through the abort path as `timed_out`, naming the in-flight stage.
- Each amended statement names its test in an `## Enforced by` entry (CLAUDE.md, #2268).

## Acceptance

- [ ] A run that exceeds its limit is stopped and ends `timed_out`, naming the in-flight stage and the limit — regression test with a planted hang under a small `max_run_s`; reddens at the merge-base.
- [ ] The watchdog fires when the engine itself is stuck between stages (not only inside a stage dispatch).
- [ ] The whole process group dies: a child that ignores TERM is gone after TERM + 10 s.
- [ ] `release` and `persist` still run after a timed-out run.
- [ ] Precedence: template `max_run_s` > `ZBUILD_MAX_RUN_S` > 20700 s, each layer tested; a non-integer or non-positive value in either is refused as `misconfigured`.
- [ ] A run that finishes inside its limit is untouched, and the watchdog is gone after the run exits (no leftover process).
- [ ] A resumed run gets a fresh limit: a run stopped at its limit, then resumed, is not stopped at once.
- [ ] Same behaviour locally and in CI — no branch on the platform, nothing read from GitHub's job limit.
- [ ] ADR-054 §9 and ADR-025 amended with `## Enforced by` entries.
- [ ] `npm test` + `npm run lint` green.

Refs #1659, #1801 (stage limit), #1932 (admission cap), #1831 (exit-path cleanup), #146 (orphan reaping), ADR-006, ADR-025, ADR-054 §6a/§9.
