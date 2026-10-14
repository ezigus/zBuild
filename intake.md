[bug] stage timeouts silently stop applying — the fallback orchestrator ignores --timeout and a hung stage reports success

> **Updated 2026-10-11:** re-checked against main 8085cd3a, after #2356 (#1932) and #2357 (ADR-068 §8). The defects below are all still present. Changes: `impact` is gone from the shipped templates (#2354), so it is dropped from the values table. Things built since that sit next to this work:
> - `runner.sh` `main` now takes a host-wide run-cap slot (#1932, ADR-059 §7) and frees it on its early exits. A timeout must not change that.
> - `plugin_hook_call` now records when each `run` starts, first thing (`stage_dispatch_mark`, `scripts/lib/stage-dispatch-mark.sh`), and every reader of a stage's result treats one older than that as absent (`stage_result_is_current`, ADR-068 §8, #2357). The per-dispatch timer goes in the same function. A stage killed at its limit before writing its result therefore has no result, and must end `timed_out`, never with the previous try's verdict.
> - The `always_run` watchdog already kills the whole group after the leader exits (#2333). Keep that when it moves to `zbuild_pg_kill`.

> **Updated 2026-10-09:** decision 9 added — the `orch-sequential` backend is retired, not kept as an option.

> **Rewritten 2026-10-09** after a design review (decisions below; previous bodies kept in the issue history). Re-verified in code against main 3611b4e6 (and again on 2026-10-11, see above). Line numbers are deliberately not used — code is named by file and function, because other PRs move lines before this one is built.

Part of #1659 (engine-enforced execution bounds — layer 1), under #1795 (Phase 2).

**Classification: ENGINE — `core/plugin-registry/lifecycle.sh` `plugin_hook_call` × `core/pipeline/strategies/*` × `core/orch/` × `core/pipeline/template.sh` × `config/templates/simple.yaml`.**

## Problem

A stage has no time limit on most paths, and where it has one it is the wrong one.

The engine runs a stage through one of two routes, and both end in `plugin_hook_call`:

- **Through an orchestrator backend** — top-level stages with `roles:` (intake, plan, pr, review lenses …) go through `_strategy_run_map` / `_fanout` / `_sequential`, which call `orch_collect --timeout "${ZBUILD_ORCH_TIMEOUT:-300}"` — a flat 300 s for every stage, not the stage's own setting.
- **Called directly** — cycle members (build, test, design, test-author, the gates), parallel-group members and roleless leaves call `plugin_hook_call` in `runner.sh` with **no limit at all**. These are the long stages.

Three things make it worse:

1. **A missing backend silently removes the limit.** `orch_load_backend` (`core/orch/contract.sh`) falls back to `orch-sequential` when the configured backend is not found, and `_orch_load_backend` does the same when the config cannot be read. `orch-sequential` ignores `--timeout` by its own comment (*"accepted for contract compatibility but ignored"*). The fallback's warning is discarded (`orch_load_backend "$backend" 2>/dev/null || true`), and no `backend.degraded` event is emitted — which ADR-011 rule 2 requires and the memory backend already does. Measured with a 20 s hang under a 2 s limit: bash-parallel stopped it at 2 s (rc 1); sequential ran 20 s and **reported success**.
2. **`router.timeout_s` is not a stage limit.** It bounds **one model call** (`_route_resolve_timeout`: template `router.timeout_s` > `ZBUILD_ROUTER_TIMEOUT` > manifest > 300). A stage that makes several calls runs past it; a stage that makes none (test, shape-floor, secret-scan, gate-aggregator) has nothing. The one exception is the `always_run` teardown stages, where `_runner_dispatch_always_run` reuses `router.timeout_s` as a whole-stage bound — so the same key means two things.
3. **Killing is done four different ways.** `zbuild_pg_kill` (`scripts/lib/proc-group.sh`, group, 1 s default grace) is the shared helper; the `always_run` watchdog hand-rolls its own (2 s); `_orch_local_collect_results` kills single PIDs (0.5 s); `timeout -k` sites use 10 s.

ADR-011 also still names `orch-sequential` as the default backend; the code default is `bash-parallel` (`core/config/config.sh`).

## Decisions (2026-10-09)

1. **One timer per dispatch, in `plugin_hook_call`, for the `run` hook.** The hook runs as its own process group (`set -m`, as the `always_run` watchdog and the router's model spawn already do) with a timer beside it. Every route reaches it: both strategy routes, all direct `runner.sh` sites, and `always_run`. It also gives teardown a process group to signal (the gap the `#2024` comment in `plugin_hook_call` describes). Fan-out and the cycle/retry loop are **not** changed — they are different mechanisms and stay separate.
2. **Kill through `zbuild_pg_kill`, TERM → KILL after 10 s.** One implementation everywhere: the `always_run` watchdog and `_orch_local_collect_results` move to it as well.
3. **Two settings, same layering as the router's:** template per-stage **`stage_timeout_s`** > **`ZBUILD_STAGE_TIMEOUT_S`** > engine default **90 min**. The name sits beside `negctl_timeout_s` and is not confusable with `router.timeout_s`.
4. **`router.timeout_s` means one model call, nothing else.** The `always_run` stages move to `stage_timeout_s` with their current values (release 30 s, persist 120 s).
5. **Template values now, at 1.5 × the longest dispatch measured**, never below the stage's `router.timeout_s`, with a **10-minute floor** (the floor does not apply to the `always_run` stages, whose short bounds are deliberate — they run inside the EXIT trap). The template loader **rejects** a `stage_timeout_s` below the same stage's `router.timeout_s`.
6. **A timeout is the existing `timed_out` disposition** (ADR-054 §6a), naming the stage and the limit; the stage's existing `retry:` budget applies; **each retry and each map member gets a fresh timer**.
7. **No flat backend limit.** The strategies stop passing `ZBUILD_ORCH_TIMEOUT`; the per-dispatch timer is the only stage limit, so a stage's `stage_timeout_s` is not undercut by a 300 s collect deadline.
8. **A missing or unreadable backend is a hard error** (`misconfigured`, naming the backend) — no silent fallback.
9. **`orch-sequential` is retired.** It ignores the limit it is given, so no future change may pick it up by accident. Delete `plugins/tool/orch-sequential/` and its golden, remove the built-in lookup in `orch_load_backend` (`core/orch/contract.sh`), and make a config naming `sequential` / `orch-sequential` fail as `misconfigured` like any unknown backend. Tests that use it as a fixture move to `orch-mock` (or `bash-parallel` where real process behaviour is the point); tests of the plugin itself are deleted. The **`sequential` strategy** (`_strategy_run_sequential`, template `strategy: sequential`) is a different thing and stays.

### Values for `config/templates/simple.yaml`

Measured from 72 local runs (2026-07 → 2026-10), longest single dispatch per stage. Samples of 8–12 for several stages; CI tends to be slower — hence the floor.

| stage | longest | 1.5× | `router.timeout_s` | `stage_timeout_s` |
|---|---|---|---|---|
| test | 58.1 m | 87 | — | **90 m** |
| build | 45.2 | 68 | 15 m | **70 m** |
| design | 41.0 | 62 | 10 m | **65 m** |
| plan | 11.9 | 18 | 5 m | **20 m** |
| test-author | 6.6 | 10 | 15 m | **15 m** |
| acceptance-gate, issue-acceptance, spec-coverage, spec-correspondence, review_lenses | ≤ 5.4 | ≤ 8 | 5–10 m | **10 m** |
| intake, pr, hydrate, secret-scan, shape-floor, design-gate, gate-aggregator, assertion-integrity, review-aggregator | ≤ 0.3 | < 1 | ≤ 1 m | **10 m** |
| release / persist (`always_run`) | — | — | 30 s / 120 s today | **30 s / 120 s** (moved, unchanged) |
| any stage not listed | | | | 90 m default |

## Not in scope

- A whole-run lifetime limit and resume after a timeout — #1944 / #1659.
- Changing how fan-out or the cycle/retry loop work.

## ADR

- **ADR-054 §9 (per-stage configuration surface) — amended:** adds `stage_timeout_s`, its precedence, the default, and the loader rule (≥ `router.timeout_s`); states that every `run` dispatch is bounded in `plugin_hook_call` and ends `timed_out` (§6a) on expiry.
- **ADR-017 — amended:** `router.timeout_s` bounds one model call only; the `always_run` stages use `stage_timeout_s`.
- **ADR-011 — amended:** `orch-sequential` is retired; the default backend is `bash-parallel`; a missing or unreadable backend is `misconfigured`, not a fallback (supersedes graceful-degradation rule 2 for the orchestrator); strategies pass no collect timeout.
- Each amended statement names its test in an `## Enforced by` entry (CLAUDE.md, #2268).

## Acceptance

- [ ] A hung `run` hook is terminated at its limit on **every** dispatch route — map, fanout, sequential strategy, cycle member, parallel-group member, roleless leaf, `always_run` — under **every** backend (bash-parallel, ruflo-hive, mock), and ends `timed_out` naming the stage and the limit. Regression test with a planted hang reddens at the merge-base.
- [ ] The whole process group dies, not just the leader: a hook that spawns a child which ignores TERM leaves nothing running after TERM + 10 s.
- [ ] Precedence: template `stage_timeout_s` > `ZBUILD_STAGE_TIMEOUT_S` > 90 min, each layer tested.
- [ ] The loader rejects `stage_timeout_s` below the stage's `router.timeout_s`, and a non-integer value.
- [ ] A retry and each map member get a fresh timer.
- [ ] `simple.yaml` carries the values above; `release`/`persist` use `stage_timeout_s` and keep 30 s / 120 s; `router.timeout_s` is no longer read by `_runner_dispatch_always_run`.
- [ ] The strategies pass no flat `ZBUILD_ORCH_TIMEOUT`; a `plan` dispatch longer than 300 s and inside its `stage_timeout_s` completes.
- [ ] `orch-sequential` is gone: `plugins/tool/orch-sequential/` and `tests/golden/orch-sequential-capabilities.golden` deleted; a guard test fails if the plugin directory exists or any file outside `docs/adr/` names `orch-sequential`; a config naming `sequential` ends `misconfigured`. Every test that used it as a fixture passes on `orch-mock` or `bash-parallel`.
- [ ] A configured backend that cannot be found, or an unreadable config, fails the run as `misconfigured` naming the backend — tested from the **installed** tree (`install.sh` layout), not only the checkout.
- [ ] `always_run` and `_orch_local_collect_results` kill through `zbuild_pg_kill`; no hand-rolled TERM/KILL sequence remains for stage dispatch.
- [ ] Before writing tests: `grep -rl` for `orch-sequential`, `ZBUILD_ORCH_TIMEOUT`, `router.timeout_s` and the `always_run` watchdog in `tests/` — every test that pins them is in scope (CLAUDE.md, test scope discovery).
- [ ] ADR-054 §9, ADR-017 and ADR-011 amended with `## Enforced by` entries.
- [ ] `npm test` + `npm run lint` green.

Refs #1659, #1944, #1932, ADR-054 §6a/§9, ADR-017, ADR-011, ADR-057 §1, #2024, #2287, #2333.
