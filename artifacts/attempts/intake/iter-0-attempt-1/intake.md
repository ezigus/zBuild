remove the impact stage from the shipped templates — nothing consumes it, and it missed every gap that blocked a build

Part of #1795 (Phase 2 — stop the silent waste). Implements an amendment to **ADR-068 §1 and §8**.

**Build Mode: Dogfood.** ADR-057 gate 2 (template / stage roster) is retired (#2351), and the decision below is made, so gate 1 no longer applies. The change touches no `.github/workflows/**` file (gate 3b).

## Decision (2026-10-10)

**Remove `impact` from the flow of both shipped templates, `config/templates/simple.yaml` and `config/templates/deployed.yaml`.** The plugin `plugins/agent/impact/` and its unit tests stay on disk. This is a template change, not a plugin retirement.

The decision rests on the evidence below. `impact` costs real time and money every round, nothing reads what it writes, and on the runs measured it named none of the gaps that actually blocked a build.

## Evidence

Every run of the GitHub dogfood workflow "zbuild daemon (label-triggered pipeline)" from 2026-09-13 to 2026-10-09 was checked: 60 runs, all artifacts available, 58 of which dispatched `impact` (75 calls in all). Ten of them ran after ADR-068 put `impact` inside `delivery_loop`. Each file `impact` named was judged against the PR that finally merged for that issue.

| | |
|---|---|
| Runs where `impact` named missing files | 15 (25 issue/file pairs) |
| Named by the model, actually needed | 4 |
| Named by the model, not needed | 4 |
| Named by the deterministic prefilter (`_impact_scope_prefilter`) | 17 — **none** needed (#2032's run repeated the same list 6 times) |
| Runs where build had to ask for a file design left out of scope | 14 (19 distinct files, e.g. #1752's two mutation tests, #1844's three lint tests) |
| …of those, named by `impact` beforehand | **0** — it reported `complete` every time |
| Correct findings in the ADR-068 era (10 runs) | 0 |
| Cost | median ~159 s per call, ~233 min total; $22.89 over the 38 calls that reported cost |
| Failures | 13 envelope-format breaks (recovered), 1 `error` (#1848); #1972 lost a 24-min run to it |

Twice `impact` named the exact file a build then failed on: #1849 (`core/pipeline/verdict.sh`, round-1 build ~95 min) and #1837 (`tests/unit/artifact-type-retirement-test.sh`, round-1 build ~81 min). Because nothing consumes `impact.json`, those rounds were lost anyway. Wiring its findings into design might have saved 2 rounds in 58 runs; against that stand ~4 h of `impact` time, the cost, and a zero hit rate on the gaps that blocked builds. Keeping it is not worth it.

Limits: a small sample; "not needed" is judged against the merged PR; July–September local runs were not analysed.

## What `impact` is today (main d4272ae5)

- In both templates it sits inside `delivery_loop`, between `design_verify_cycle` and `build_test_cycle`, so it runs once per outer round.
- It writes `impact.json` (`{verdict: complete|incomplete, missing: [...]}`); no plugin manifest declares it as an input. Downstream only `impact-summary.md` is read, and that reports `pass` even when the result is `incomplete` (`plugins/agent/impact/plugin.sh`).
- `impact` is the only caller of `_impact_scope_prefilter` (`plugins/agent/impact/plugin.sh`), which lists the test files a shape-changing diff must touch. **Accepted loss:** after this change the list is not computed. On the evidence it was wrong 17 times out of 17. The useful version of it is #1722 (a failing `shape-floor` names the files itself) and #1874 (compute the floor at scope time).

## Scope

Re-run `/usr/bin/grep -rln '\bimpact\b' tests/` before implementing (72 files on d4272ae5). Almost all drive the plugin standalone or build their own stub plugin; they are unaffected.

### Must change

| File | Why |
|---|---|
| `config/templates/simple.yaml` | remove `- impact` from `delivery_loop`'s `flow:`, its stage block (`impact:` and the comment banner above it), the `delivery_loop` comment describing it, and the stale `prior_impact_feedback` / "impact stage placed AFTER this cycle" comments in the `design_verify_cycle` banner |
| `config/templates/deployed.yaml` | the same: `- impact` from `delivery_loop`'s `flow:` and its stage block |
| `docs/adr/ADR-068-*.md` | amend §1 (flow becomes "design loop → build loop") and §8 (`impact` no longer listed among the stages that answer findings); add an `Amended` header entry and update `## Enforced by` for §1 |
| `tests/unit/template-simple-yaml-test.sh` | `_expected_stages` drops `impact`; the stage count and every `_TPL_STAGES[N]` index after it shift; the `[SPEC-3] impact roles/io/timeout/max_turns` assertions are deleted |
| `tests/integration/core-pipeline-cycle-build-test-wiring-test.sh` | T1 pins `delivery_loop` as `design_verify_cycle,impact,build_test_cycle` → `design_verify_cycle,build_test_cycle` |
| `tests/integration/deployed-template-e2e-test.sh`, `tests/unit/template-blocking-reset-test.sh` | read `deployed.yaml`; check for any roster/index pin |

### Must check — stub plugins that become unused

These drive the shipped `simple.yaml` with stub plugins, including an `impact` stub. After the change the stub is never dispatched; delete it and any comment that says the runner walks to `impact`:

- `tests/lib/run-status-comment-mock-roster.sh`
- `tests/integration/cycle-gate-unavailable-aborts-run-test.sh`
- `tests/integration/cycle-rate-limit-aborts-run-test.sh`
- `tests/integration/cycle-on-max-pipeline-continues-test.sh`
- `tests/integration/cycle-acceptance-terminal-failure-test.sh`

### Verified not affected

- All `impact` plugin unit tests (`impact-*-test.sh`), `design-impact-cycle-*-test.sh`, `impact-pipeline-test.sh`, `impact-prefilter-781-regression-test.sh` — they drive the plugin directly.
- `tests/unit/core-pipeline-template-test.sh` (`_TPL_STAGES[3] is impact`) — a fixture template, not a shipped one.
- `tests/unit/test-author-test.sh`, `tests/unit/summary-retire-wiring-test.sh` — mention `impact` in comments or a regex over other stages; re-run to confirm.
- `docs/ARCHITECTURE.md` lists `impact` among the agent plugins; the plugin stays, so that line stays.

## Acceptance

- [ ] A test asserting `impact` is absent from `delivery_loop` in **both** shipped templates is written first and reddens on main (state the red step in the PR body).
- [ ] `plugins/agent/impact/` and its unit tests are untouched and still pass.
- [ ] `tests/unit/template-simple-yaml-test.sh` and `core-pipeline-cycle-build-test-wiring-test.sh` reflect the new roster, count and indices.
- [ ] ADR-068 §1/§8 amended in the same PR; `npm run lint` (incl. `lint-adr-enforced-by.sh`) is green.
- [ ] A dogfood run completes with no `impact` stage and no stage-resolution warning.

## History

Filed while working #1658 (run `20260801085257-41853`, where `impact` ran 184 s, named 3 files, and nothing read them). Originally under #1600; re-parented when Initiative 1.3 (#1818) reorganised into phases. `impact` was pulled out of the design cycle after an unbounded false gap livelocked a run (#970), then placed in `delivery_loop` by ADR-068. `route-tautology-to-design-test.sh`, once the main casualty, was deleted with `route_back`. #1894 (absent-input rule) is closed. Earlier "Design Decision needed" marking is resolved by the decision above.

Refs #1600, #970, #1658, #1722, #1874, ADR-040, ADR-046, ADR-068.

---

## Contract

This issue touches a surface that **[ADR-054](../blob/main/docs/adr/ADR-054-stage-contract.md) / [ADR-055](../blob/main/docs/adr/ADR-055-inter-stage-data-contract-v2.md) redefine** (Phase 0, #1819). Implement against the contract, not against today's engine — if the two disagree, the ADR wins.

- Initiative goal and the domain checklist this must satisfy: #1818

## Additional context from issue comments

**Recurrence — run `20260801151212-99189` (issue #1635).**

`impact` ran for **230s**, returned `verdict=incomplete`, and named 2 files it wanted added to scope (`tests/unit/worktree-location-test.sh`, `tests/integration/cleanup-cli-e2e-test.sh`). Discarded, as designed — `design_verify_cycle` had already converged one stage earlier.

Second consecutive dogfood where impact produced an `incomplete` verdict that nothing could consume (#1658 was the first). Roughly 7 minutes of LLM time across the two runs, zero effect on either.

Worth noting for whoever plans this: both files it named were in fact reasonable additions, so the stage is not producing *noise* — it is producing usable output into a dead end.

---

**Third data point, and it cuts both ways: in run `20260803183642-2350` (#1669) impact produced the exactly-correct answer, and because nothing consumes it the run died.**

[Run 30841982036](https://github.com/ezigus/zBuild/actions/runs/30841982036) — 3h15m, `rc=7 blocked_on_scope`, no PR.

## `impact.scope.expanded` expands nothing

`plugins/agent/impact/plugin.sh:513` states it outright:

```bash
# Per-gap scope.expanded event for postmortem discoverability.
emit_event "impact.scope.expanded" "plugin=impact" \
    "step_id=$_step_id" "files_to_add=${_files:-none}"
```

It is telemetry with a verb for a name. Nothing reads it. (Worth renaming on its own merits — I initially misread the #1686 run as "scope was expanded and build ignored it", because that is what the event says happened.)

## What that cost in this run

#1669 changes the cycle feedback event taxonomy, so it touches `config/event-schema.json` — which is in `config/shape-change-paths.txt`, so shape-floor demands the event-sequence goldens be in the diff.

```
18:47  impact → verdict=incomplete, names 9 files missing from scope, including
                tests/golden/full-pipeline/event-sequence.golden
                tests/golden/parity/event-sequence.golden
18:47  build.scope_injected  source=design  file_count=11    <- impact's 9 absent
19:33  shape_floor.fail missing_floor_files  → gate fail     (iter 1)
20:48  shape_floor.fail missing_floor_files  → gate fail     (iter 2)
21:24  build edits them anyway → 7 × build.scope.violation
       build.commit.skipped reason=scope_violation
21:52  cycle.scope.denied "cycle scope_policy not expandable"
       ✗ terminated rc=7 blocked_on_scope
```

**Impact was right.** It named both goldens 3 hours before the run died on their absence, and its reasoning in the transcript is better than the design's:

> `tests/golden/full-pipeline/event-sequence.golden` and `tests/golden/parity/event-sequence.golden` both exist. Neither currently contains `cycle.*` events (cycles are opt-in via `ZBUILD_CYCLES_ENABLED=1`). If the change touches only cycle-gated paths these goldens will not need updating — **but they must be in scope so the design agent can confirm that claim after reading the actual diff.**

That is exactly the right call, and it is also correct that no content change was needed — shape-floor requires presence-in-diff, not correctness.

## Bearing on this issue

Both readings are strengthened, which is why I am recording it here rather than arguing for one:

- **For removal:** the stage ran 5m34s, produced a correct answer, and the answer went nowhere. That is the case this issue makes, now with a run that *failed* rather than merely wasted the work.
- **Against removal:** the answer it produced would have saved 2h20m and delivered a PR. The defect is the missing wire, not the analysis.

What is not defensible is the present state — paying for the analysis, naming the event after an action it does not perform, and discarding the result. Either wire `missing[].files_to_add` into the build write-scope (which needs #1711's escalation path, since only design can widen scope today), or delete the stage. Also relevant: run `20260803093634-57718` (#1686) shows the same pattern without the fatal ending — impact named a re

[… issue comments truncated at 4000B — read the issue for the full thread]
