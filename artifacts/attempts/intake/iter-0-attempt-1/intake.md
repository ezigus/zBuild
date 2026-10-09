[bug] the gtimeout-first probe is hand-copied at six sites and nothing stops a bare `timeout` — factor a shared helper and lint for it

> **Updated 2026-10-09** (re-verified against main 3611b4e6, in code): the six probes are `core/router/route.sh:1046` (sync) and `:1943` (loop), `scripts/run-tests.sh:34`, `scripts/run-mutation.sh:124` (the 10-08 note's `:115` was stale), `scripts/lib/acceptance-block.sh:366` (`-k` probe `:370-376`), `scripts/lib/gh-automation.sh:191`. `plugins/agent/build/lib/summary.sh:433` is a **caller** of `_acceptance_timeout_prefix`, not a seventh probe. The table below is corrected. Added: the ADR this implements (ADR-036 amendment), constraints, and the Build Mode re-derivation.

**Build Mode: Dogfood** — ADR-057 gate 2 matches literally (`acceptance-block.sh` is in `_runner_contract_lib_closure`, so this run's acceptance gate executes the helper build writes), but ADR-057 §5 makes a self-grading change `By-hand` *by default*, not forbidden. Overridden because the helper only chooses `gtimeout` / `timeout` / none: a defect makes the gate error loudly or run unbounded — it cannot turn a failing test into a pass. The constraint below pins that. Gates 1, 3 and 3b do not match (no workflow file, no pre-intake code).

> **Updated 2026-10-08** (Phase 2 re-verification against main 2ae004fa, checked in code, not from this text): defect re-confirmed — six probes in five files and a bare `timeout` at `scripts/release.sh:629`; no lint exists. Line refs moved: `core/router/route.sh` `:1046` (sync) and `:1943` (loop), `scripts/run-mutation.sh:115`, `scripts/lib/acceptance-block.sh:366` (`-k` probe `:371-376`), `plugins/agent/build/lib/summary.sh:433`. `scripts/run-tests.sh:34` and `scripts/lib/gh-automation.sh:191` are unchanged. Conflicts textually with #1730 in `route_to_model_loop`; land one, then the other.



> **Updated 2026-09-29** (Initiative 1.3 alignment audit, main 900db6b0): rescoped to the leftover. The headline bug — a bare `timeout` in the build false-completion guard — was fixed by 747215b8 (#2113); what remains is the duplicated `gtimeout`-first probe (six sites in five files) and the missing lint against a bare `timeout`. Title changed to match.

Part of #1795 (Phase 2 — stop the silent waste).

*Re-parented: originally filed under #1738, closed when Initiative 1.3 (#1818) reorganised into phases.*

## Fixed (history)
`plugins/agent/build/lib/summary.sh` called `timeout` bare in `_build_guard_false_completion`, so on a macOS host with only `gtimeout` every `empty_diff` build carrying an acceptance block was falsely classified `inert_build`. The guard now builds its command with `_acceptance_timeout_prefix` (`summary.sh:402-407`), which probes `gtimeout` first — 747215b8 (#2113); #2138/#2142 later bounded it by the measured time.

## Problem (remaining)
`install.sh:28-37` documents why the probe exists: **macOS has no `timeout`** — Homebrew's coreutils installs it as `gtimeout` only. Every correct call site therefore repeats the same "gtimeout, else timeout" resolution, and each copy is hand-written:

| Site | Probe |
|---|---|
| `core/router/route.sh:1046` | sync path, `_tout_cmd=("gtimeout" …)` |
| `core/router/route.sh:1943` | loop path, same shape |
| `scripts/run-tests.sh:34` | `_rt_tout_bin` |
| `scripts/run-mutation.sh:124` | `_mut_tout_bin` |
| `scripts/lib/acceptance-block.sh:366` | `_acceptance_timeout_prefix` — also probes `-k` support (`:370-376`) |
| `scripts/lib/gh-automation.sh:191` | `timeout_cmd` |

Nothing prevents a seventh copy from getting it wrong, or a new bare `timeout` — which is how the fixed bug above shipped. One bare call remains on main: `scripts/release.sh:629` (`timeout "$checks_timeout" "$gh_pr_cmd" pr checks …`). That is release tooling (Initiative 1.1); the lint below must either cover it or exempt it explicitly, and fixing its behaviour is not in this issue's scope.

## Fix
Factor the probe into one shared helper (e.g. `scripts/lib/timeout-cmd.sh`), convert the six sites to it, and add a lint that fails on a bare `timeout` call in `core/`, `scripts/` or `plugins/` — consistent with this EPIC's principle: *delete the duplicate implementation rather than patch it in place.* `_acceptance_timeout_prefix` already handles the `-k` probe and is a candidate to become the helper.

## ADR
No ADR states this rule today. ADR-036's "Both gates build the bound through one helper, `_acceptance_timeout_prefix`" paragraph covers only the acceptance gates. This PR **amends ADR-036** (dated amendment): *every timeout bound in `core/`, `scripts/` and `plugins/` is resolved through the shared helper; a bare `timeout` call is a lint failure* — with an `## Enforced by` line naming the lint (CLAUDE.md, #2268).

## Constraints
- **No false pass.** The helper's only job is to choose the binary (and `-k` support where a site needs it). When neither binary exists it must behave as today: the caller runs unbounded (acceptance) or with its existing fallback — never skip the command and return 0.
- **rc semantics unchanged.** Every site keeps exit 124 = timed out and 137 = killed exactly as now (ADR-021 R2: the router must not translate 124/137; ADR-036 "a signal is not a timeout").
- **`-k` probe stays once-per-process** (`_ACCEPTANCE_TIMEOUT_KILL_OK`), and `_acceptance_timeout_prefix` keeps its name and `_ACCEPTANCE_TOUT` contract — `plugins/agent/build/lib/summary.sh:23,433` sources and calls it.
- **The no-`timeout`-host test must not use `scripts/lib/test-helpers.sh:374`'s mock**: that mock is a `timeout` that ignores its duration and just `exec`s, so a test built on it cannot see whether a bound was applied. Use a PATH with only a recording `gtimeout` shim.
- `scripts/lib/test-helpers.sh` (test-only mock) is exempt from the bare-`timeout` lint, with the reason in the lint.

## Acceptance
- [ ] A shared helper exists; all six probe sites use it.
- [ ] A lint or test fails on a bare `timeout` call site in `core/`, `scripts/`, `plugins/` — red first against a planted bare call; `scripts/release.sh:629` is covered or explicitly exempted with a reason.
- [ ] Guard: on a host with only `gtimeout`, each converted site still bounds its command (regression test simulating the no-`timeout` host).
- [ ] Guard: a genuinely failing acceptance testfile still yields `inert_build` (#1532 unregressed).
- [ ] ADR-036 amended with the rule above and an `## Enforced by` entry naming the lint.
- [ ] `npm test` + `npm run lint` green.

Where: the six sites above, `install.sh:28-37`, `scripts/release.sh:629`. Refs #1738, #1532, #2113, #996, #1600.

---

## Contract

This issue touches a surface that **[ADR-054](../blob/main/docs/adr/ADR-054-stage-contract.md) / [ADR-055](../blob/main/docs/adr/ADR-055-inter-stage-data-contract-v2.md) redefine** (Phase 0, #1819). Implement against the contract, not against today's engine — if the two disagree, the ADR wins.

- ADR-054 §4-§6 — the engine acts on `disposition`, not on a re-derived verdict string.
- Initiative goal and the domain checklist this must satisfy: #1818
