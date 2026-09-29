[Phase 0/F] migrate the plan plugin to contract v2

> **Updated 2026-09-29 (after run [36534233685](https://github.com/ezigus/zBuild/actions/runs/36534233685))**: added *Direction* — the previous run failed on three choices this section now rules out.
> **Updated 2026-09-29** (Initiative 1.3 alignment audit, main 900db6b0): Folds in now uses the ADR-054 §6a words (`timed_out`, `out_of_turns`), names the rc=10 path and `router.retries` knob to retire, and marks the #1727 `return 1` as already fixed.

Part of #1819 (Phase 0 — the stage↔engine contract). Member of the **F set** — one plugin per PR, each independently verifiable.

Migrate `plugins/agent/plan` to contract v2. The engine reads v1 and v2 side by side (#1824), so this plugin moves on its own and nothing else has to move with it.

## Direction — read before designing

Run [36534233685](https://github.com/ezigus/zBuild/actions/runs/36534233685) got most of this migration right and failed on three choices. Do not repeat them:

1. **Get the goal from the `intake_goal` input, not from `ZBUILD_GOAL`.** Replace plan's `goal_string` (`source: external`) input with `id: intake_goal, required: true`, and read its path from `ZBUILD_STAGE_INPUTS` — exactly as plan already reads `scope_manifest`, and as issue-acceptance, spec-coverage, review-lens, review-report and security-lens already do. Intake writes `intake.md` in both `--goal` and `--issue` runs. The engine does **not** set `ZBUILD_GOAL` in `--issue` runs and nothing checks that an external input is supplied, so relying on it breaks every `--issue` run. This is how the "no artifact paths in code" item below is met — not by deleting the goal source.
2. **One result file: `plan.json`.** Put `result_contract: 2`, `verdict`, `disposition` and a **non-empty `reason`** into `plan.json` on every exit path, including success (e.g. `reason: "decomposed the goal into N steps"`). The engine rejects a result without `reason` (`core/pipeline/verdict.sh:394-404`) and marks the stage `error`. Do **not** add a second file such as `plan-result.json`: ADR-054 allows one result file, and a new artifact changes the parity goldens outside this issue's scope.
3. **No engine changes.** Do not edit `core/pipeline/runner.sh` to supply the goal. The linear loop there is not taken by the shipped templates (#1807). The only runner change in scope is deleting the leaf path's rc=10 branch (see *Folds in*).

A test must pass plan's real success `plan.json` through `runner_read_stage_verdict` and get `pass` with no contract violation.


## What this plugin adopts

- **v2 result file** (#1821) — `result_contract: 2`, and mandatory `verdict`, `disposition`, `reason`. Anything this plugin currently communicates through a sidecar, an event, or a bare exit code moves into the result; plugin-specific detail goes under `data`, namespaced.
- **`disposition`** (#1822) — the plugin declares *how* it stopped. It no longer decides its own retry policy: the engine's response table (`core/pipeline/disposition.sh`) decides whether a word retries, and the template's per-stage `retry:` sets how many times (`_runner_retry_budget`, `core/pipeline/runner.sh`). Use the ADR-054 §6a words; a model-call failure is named by `router_reason_disposition` (`scripts/lib/router-rc-classify.sh`), not by the plugin.
- **rc ∈ {0,1}** (#1823) — every other exit code this plugin returns today is expressed as a `disposition` instead.
- **`valid_verdicts`** declared in the manifest and enforced (#1708) — a verdict outside the declared set becomes a structural failure.
- **Router budgets** in the manifest (#1816) rather than resolved only from the template.
- **A `primary: true` output** declared in the manifest. Prerequisite for #1850: `no primary declared -> pass` cannot be flipped until every dispatched stage has one (34 of 56 manifests do today; the rest are personas and role-resolved backends). This plugin already declares one (`plugins/agent/plan/manifest.yaml:77`), so this item is already met.
- **`provides.events`** declared (#1717) and **`provides.role`** declared (#1704).
- **Name-matched inputs** (#1825) with the engine resolving paths (#1826). The manifest declares only the artifact `id` and `required:` — **no producer stage, no path, no type** — and every path this plugin constructs in code is deleted. *(Amended 2026-08-12 by #1768: this read "`from:`-style inputs", i.e. the consumer naming its producer as `from: <stage>.<output_id>`. ADR-055 §1 removed that — the producer name is redundant given output-id uniqueness, and it could not express a backwards edge. Any `source: artifacts` or `source: cycle_feedback` input in this plugin becomes an ordinary name-matched input.)*
- **`cleanup`** (#1829) — if the plugin holds live resources, `release` frees them; if it has nothing to free, the hook is absent and that is recorded, not implied.

## Folds in

`plan` is the stage with the worst blast radius, because it is a leaf stage and its v1 exit codes are still load-bearing:

- A turn-budget exhaustion returns **rc=10** `scope_too_large` (`plugins/agent/plan/plugin.sh:849`), which the runner's leaf path turns into an aborted run (`core/pipeline/runner.sh:3471-3487`). Under v2 this is `disposition: out_of_turns` (ADR-054 §6a; `router_reason_disposition` already maps `router_out_of_turns` to it), reported with rc=1, and the runner's rc=10 branch is deleted.
- A timeout is `disposition: timed_out`, not `interrupted`. `interrupted` is reserved for an outside signal.
- plan carries its own `router.retries: 1` and `router.retry_on_exhaustion: 1` (`plugins/agent/plan/manifest.yaml:53-55`). The stage-level retry budget is now the template's per-stage `retry:`, so each knob either goes or the PR records why it still has to stay.

*(History: this section also said a hand-rolled `return 1` at `plugin.sh:651-656` made the #1052 recovery block unreachable. #1727 fixed that in 3e2151df (PR #1883); `plugin.sh:664-697` now falls through to recovery, so a timeout already resumes from `plan-context.json`.)*

Also: #1756 (the plan anti-pattern gate cannot fire — case-mismatched extraction, and the discipline verdict has no consumer). Still open.

## Acceptance

- [ ] The plugin writes a conformant v2 result on **every** exit path — success, failure, and interruption — in `plan.json` only, with a non-empty `reason`; the engine's reader accepts each one (no `contract_violation`).
- [ ] `valid_verdicts` is declared and every verdict the plugin can emit is in it; a test drives each one.
- [ ] The plugin constructs no artifact paths in code — assert by grep over its `plugin.sh`. Inputs (`scope_manifest`, `intake_goal`) come from `ZBUILD_STAGE_INPUTS`; the goal is never read from `ZBUILD_GOAL`.
- [ ] Router budgets resolve from the manifest, and the template override still wins where one is set.
- [ ] Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output, and the parity goldens (`tests/golden/parity/*`) unchanged.
- [ ] The manifest declares a `primary: true` output (or the issue records why this plugin is not dispatched as a stage).
- [ ] `npm test` green with the tree committed first, so the mutation tier engages.
- [ ] Reddens at the merge-base.

Refs #1807, #1819, #1821, #1822, #1823, #1824, #1825, #1826, #1829, ADR-054, ADR-055.
