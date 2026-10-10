[bug] nothing caps concurrent pipeline runs on one host — too many runs start at once and the OS, not zBuild, decides what dies

> **Updated 2026-10-09** (re-verified against main 3611b4e6): all cited code still present (line numbers removed from this issue — they drift as other PRs land). **Changed:** the cap now ships **off by default and fail-open** (see Constraints), the open question is settled (flat run count), and the ADR this implements is named. Those changes are what make it dogfoodable.

> **Updated 2026-10-08** (Phase 2 re-verification against main 2ae004fa, checked in code, not from this text): defect re-confirmed — the `NOT A CAPACITY CAP` comment in `core/state/issue-lock.sh` quoted exactly; the per-issue lock is taken by `zbuild_issue_lock_acquire` inside `runner.sh` `main()` and released by `zbuild_issue_lock_release` in the exit trap. Coordinate with #1944: both decide whether a run is dead; pin `zbuild_run_is_live` as it is today, or settle #1944 first.



> **Updated 2026-09-29** (Initiative 1.3 alignment audit, main 900db6b0): now layer 0 of #1659; the ADR-059 per-issue lock has landed (#1688), so "zBuild has neither" is corrected to "zBuild has the mutex, not the cap", and the 2026-08-24 correction about the 32h incident is folded into the body.

Part of #1659 (engine-enforced execution bounds — layer 0, admission), under #1795 (Phase 2).

**Classification: ENGINE — run admission.**

## Problem

Nothing limits how many pipeline runs start on one host. Each run spawns a model agent loop, a worktree, and (via the `test` stage) a nested `runner.sh` running the full suite. Six concurrent runs will exhaust memory on a laptop, and the failure mode is the OS killing processes at random rather than zBuild refusing anything.

The code says so itself, in the header comment of `core/state/issue-lock.sh` — *"NOT A CAPACITY CAP … That is a different control and zBuild still lacks it (#1932)."*

## What this does NOT fix

The 8-process / 32-hour incident (8 of 10 cores, load average 21) was first cited as this issue's motivation. **That was wrong.** A counted cap prevents too many runs *starting*; those runs had already started and never stopped. That failure is #1944 (run lifetime bound). Three distinct controls:

| failure | what fixes it | status |
|---|---|---|
| A run **ends** and leaves children behind | `always_run: [release]` — every stage's cleanup hook fires on every exit path | **#1831, landed** |
| A run **hangs or spins forever** and never reaches its exit trap | a run lifetime bound | **#1944** |
| **Too many** runs start at once and exhaust the box | a host-wide counted cap | **this issue** |

## Prior art — legacy shipwright had exactly this, and zBuild dropped it

`legacy/scripts/sw-pipeline.sh:326` refuses on a host-wide count:

```
Refusing to start: $active active pipeline(s) already running (max=$SHIPWRIGHT_MAX_ACTIVE_PIPELINES per host)
```

Its lock files are named `<pid>.json`; `issue_or_goal` is metadata *inside* the file, used only so the error can name the blocker (`sw-doctor.sh:964`, `_describe_blocking_lock`). Two runs of one issue are both admitted.

Worth taking from its shape: **`reap_stale_pipeline_locks` reads the recorded PID, checks liveness, and removes dead entries *before* the gate runs** — rather than deciding lazily and letting a dead holder block a live run.

## This is NOT the same as issue exclusivity

[ADR-059](../blob/main/docs/adr/ADR-059-issue-vs-run-keying.md) §4 requires an exclusive lock **per issue**, because runs of one issue share a worktree and would otherwise mutate one `.git/index`. That is a **keyed mutex**, it is a correctness control, and it has landed (#1688, `core/state/issue-lock.sh`).

This issue is a **counted cap** and it is a resource control. They are orthogonal — the cap does not prevent corruption, and the mutex does not prevent OOM. zBuild has the mutex; it does not have the cap.

## Scope

- [ ] A configurable host-wide concurrent-run cap — **off unless set** (see Constraints).
- [ ] Refusal is **explicit and names the blocking run(s)**, never a silent queue and never an OS kill.
- [ ] Dead holders are reaped **before admission**, using `zbuild_run_is_live` (ADR-006's staleness gate, `core/state/resume.sh`) — the same predicate ADR-059 §4 uses, not a second one.
- [ ] An override for an operator who knows what they are doing.
- [ ] Guard: a single run, and runs below the cap, are byte-identically unaffected.
- [ ] Regression test driving `cap + 1` starts; reddens at the merge-base.
- [ ] Guard: with the cap set, a failure injected into counting admits the run with a warning (fail-open test).
- [ ] ADR-059 amended with the cap rule and an `## Enforced by` entry.

## Settled (2026-10-09): count runs

The cap counts **runs**, not model agent loops. A run at `test` is heavier than one at `intake`, but a flat run count is the simpler first version and needs no per-stage weight table. A weighted count is a later change if a flat cap proves too coarse.

## ADR

No ADR states a host capacity rule today; the `issue-lock.sh` header comment and ADR-059 §4 only say the mutex is *not* one. This PR **amends ADR-059** with a dated section: *a host-wide counted cap on concurrent runs, off unless configured, fail-open, reaping dead holders with `zbuild_run_is_live` before counting* — with an `## Enforced by` entry naming its tests (CLAUDE.md, #2268).

## Constraints

- **Off by default.** No cap applies unless the operator sets one (e.g. `ZBUILD_MAX_CONCURRENT_RUNS`). Unset, the admission path does nothing new — the "byte-identically unaffected" guard covers this. Turning a default on is a separate one-line change once the cap has been used.
- **Fail open.** Any error while reaping or counting (unreadable entry, missing tool, unexpected `ps` output) admits the run and prints a warning naming the step. Only a successful count above the cap refuses.
- **A run never counts itself**, and two runs racing to start must not both be refused.
- **Override** — an env var admits the run regardless (the existing Scope item), and the refusal message says which one.
- Reaping uses `zbuild_run_is_live` as it is today (coordinate with #1944, per the 10-08 note).

Refs ADR-059 §4, ADR-006, #1688, #1764, #1944, #1831, `legacy/scripts/sw-pipeline.sh:326`.
