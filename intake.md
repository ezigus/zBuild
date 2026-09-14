[Phase 0/F] migrate the seven gate plugins to contract v2 (batched)

Part of #1819 (Phase 0 — the stage↔engine contract). Member of the **F set** — one plugin per PR, each independently verifiable.

Migrate `plugins/tool/{coverage-gate,design-gate,lint-gate,mutation-gate,secret-scan,shape-floor,gate-aggregator}` to contract v2. The engine reads v1 and v2 side by side (#1824), so this plugin moves on its own and nothing else has to move with it.

## What this plugin adopts

- **v2 result file** (#1821) — `result_contract: 2`, and mandatory `verdict`, `disposition`, `reason`. Anything this plugin currently communicates through a sidecar, an event, or a bare exit code moves into the result; plugin-specific detail goes under `data`, namespaced.
- **`disposition`** (#1822) — the plugin declares *how* it stopped. It no longer decides its own retry policy; the engine's response table does that.
- **rc ∈ {0,1}** (#1823) — every other exit code this plugin returns today is expressed as a `disposition` instead.
- **`valid_verdicts`** declared in the manifest and enforced (#1708) — a verdict outside the declared set becomes a structural failure.
- **Router budgets** in the manifest (#1816) rather than resolved only from the template.
- **A `primary: true` output** declared in the manifest. Prerequisite for #1850: `no primary declared -> pass` cannot be flipped until every dispatched stage has one (only 25 of 47 manifests do today). If this plugin already declares one, say so and move on.
- **`provides.events`** declared (#1717) and **`provides.role`** declared (#1704).
- **Name-matched inputs** (#1825) with the engine resolving paths (#1826). The manifest declares only the artifact `id` and `required:` — **no producer stage, no path, no type** — and every path this plugin constructs in code is deleted. *(Amended 2026-08-12 by #1768: this read "`from:`-style inputs", i.e. the consumer naming its producer as `from: <stage>.<output_id>`. ADR-055 §1 removed that — the producer name is redundant given output-id uniqueness, and it could not express a backwards edge. Any `source: artifacts` or `source: cycle_feedback` input in this plugin becomes an ordinary name-matched input.)*
- **`cleanup`** (#1829) — if the plugin holds live resources, `release` frees them; if it has nothing to free, the hook is absent and that is recorded, not implied.

## Batched, and why

Seven gates share one shape — run a check, emit a verdict, sometimes route back — so migrating them together is one review of one pattern rather than seven reviews of the same pattern. If any single gate turns out to need real design work, split it out rather than stalling the batch.

In scope: `coverage-gate`, `design-gate`, `lint-gate`, `mutation-gate`, `secret-scan`, `shape-floor`, `gate-aggregator`.

## Folds in

- **#1758** — a shape-floor library load failure renders as `verdict=skip`: the un-gameable floor is silently disabled with no signal. Under v2 that is `disposition: broken`, which halts. This is the single clearest instance of "unrecognized is never a failure" in the gate layer.
- **#1757** — gate-aggregator deletes `gate-feedback.md` when any failing gate declares a `route_target`, so concurrent plain failures reach no prompt. The aggregator's inputs become `from:` references (#1825) so the engine, not the aggregator, decides what is present.
- **#1760** — an unsupported `abort_when` op silently never matches: the cycle's kill-switch fails **open**. Same principle, and the gates are where it is enforced.
- **#1714** (design-gate never checks that scope paths exist) and **#1777** (a `[guard]` SPEC whose assertion cannot hold at the merge-base) are gate-logic defects, not contract defects — carry them forward, do not fix them here.

## Acceptance

- [ ] The plugin writes a conformant v2 result on **every** exit path — success, failure, and interruption.
- [ ] `valid_verdicts` is declared and every verdict the plugin can emit is in it; a test drives each one.
- [ ] The plugin constructs no artifact paths in code — assert by grep over its `plugin.sh`.
- [ ] Router budgets resolve from the manifest, and the template override still wins where one is set.
- [ ] Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output.
- [ ] The manifest declares a `primary: true` output (or the issue records why this plugin is not dispatched as a stage).
- [ ] `npm test` green with the tree committed first, so the mutation tier engages.
- [ ] Reddens at the merge-base.

Refs #1819, #1821, #1822, #1823, #1824, #1825, #1826, #1829, ADR-054, ADR-055.




---

## ⚠️ ADR-055 §9 — this plugin's summary is conditionally absent

Surfaced while migrating the **test** plugin (#1836, merged `6d21f13`). That plugin had the same defect and the issue's own acceptance checklist did not mention it — it was found by hand, after the automated run and two review passes had all gone green. Recording it here so this migration does not repeat that.

**The rule.** ADR-055 §9 (amended by #1988) requires a summary on **every terminal verdict — pass, fail and skip** — with `required: true`. Its reasoning: *"this stage ran and found nothing"* and *"this stage published nothing"* are different facts, and if absence is a legitimate state the pipeline cannot tell them apart. §9 spells out the consequence: *"`required: true`. Absence is never legitimate, so the artifact contract says so and the existing missing-output machinery enforces it — no new code."*

**Why nothing catches this today.** Both enforcement layers miss it, from opposite directions:

- Pre-flight (`core/pipeline/contract-validator.sh:382,385`, from #2000) raises only `SUMMARY_MISSING` (no summary declared) and `SUMMARY_DUP` (more than one). It never inspects `required:`. A `required: false` summary passes cleanly.
- The runtime missing-output scanner never sees it, because `_registry_output_path_rows` (`core/plugin-registry/output-paths.sh`) skips `required: false` rows by design.

So the declaration looks correct at every gate while the artifact can still go missing at runtime.

**What the test plugin's fix looked like**, as a worked reference:
- Removed the `rm -f` paths that deleted the summary on a passing verdict and on an error with no extractable output.
- Content changed to state what the stage **did** (verdict + counts), not only what went wrong — §9: *"A summary states what the stage DID."*
- The earliest exit path (its missing-`diff.patch` guard) had to publish one too; it was the single path that returned without a summary.
- `required: false` → `required: true`, at which point the existing machinery enforced it with no engine change.
- The stale-file guard was deleted: §9 notes it stops being needed once every run rewrites the file.

**Suggested acceptance addition:**

- [ ] The summary output is `required: true` and is written on **every** terminal verdict, including the earliest bail-out path. Assert by driving a passing run and a no-op/empty run and checking the file exists and names the verdict.
**In this batch specifically — `design-gate`.** `design_gate_feedback` (`${artifact_dir}/design-gate-feedback.md`) is declared `required: false` and documented as *"Written ONLY on verdict=fail — absent on a passing gate (missing == empty)."* That is the retired pre-#1988 contract stated verbatim: a passing gate publishes nothing, so a downstream reader cannot distinguish "this gate ran and cleared the design" from "this gate never ran".

The other six gates in this batch (`coverage-gate`, `lint-gate`, `mutation-gate`, `secret-scan`, `shape-floor`, `gate-aggregator`) all already declare their summary `required: true` — a sweep of every manifest carrying `summary: true` found only `design-gate`, `spec-acceptance` (#1839) and `review-aggregator` (#1842) still on the old shape. So this is one plugin in the batch, not a pattern across it.
