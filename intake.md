[Phase 0/F] migrate the review-aggregator plugin to contract v2

> **Updated 2026-09-29** (Initiative 1.3 alignment audit, main 900db6b0): the `lens_results` id mismatch and the engine-side map array are already fixed, so the map-producer section now names only what is left (the plugin still globs instead of reading `lens_result`); retry and `primary: true` wording refreshed.

Part of #1819 (Phase 0 — the stage↔engine contract). Member of the **F set** — one plugin per PR, each independently verifiable.

Migrate `plugins/agent/review-aggregator` to contract v2. The engine reads v1 and v2 side by side (#1824), so this plugin moves on its own and nothing else has to move with it.

## What this plugin adopts

- **v2 result file** (#1821) — `result_contract: 2`, and mandatory `verdict`, `disposition`, `reason`. Anything this plugin currently communicates through a sidecar, an event, or a bare exit code moves into the result; plugin-specific detail goes under `data`, namespaced.
- **`disposition`** (#1822) — the plugin declares *how* it stopped. It no longer decides its own retry policy: the engine's response table (`core/pipeline/disposition.sh`) decides whether a word retries, and the template's per-stage `retry:` sets how many times (`_runner_retry_budget`, `core/pipeline/runner.sh`). Use the ADR-054 §6a words; a model-call failure is named by `router_reason_disposition` (`scripts/lib/router-rc-classify.sh`), not by the plugin.
- **rc ∈ {0,1}** (#1823) — every other exit code this plugin returns today is expressed as a `disposition` instead.
- **`valid_verdicts`** declared in the manifest and enforced (#1708) — a verdict outside the declared set becomes a structural failure.
- **Router budgets** in the manifest (#1816) rather than resolved only from the template.
- **A `primary: true` output** declared in the manifest. Prerequisite for #1850: `no primary declared -> pass` cannot be flipped until every dispatched stage has one (34 of 56 manifests do today; the rest are personas and role-resolved backends). This plugin already declares one (`plugins/agent/review-aggregator/manifest.yaml:92`), so this item is already met.
- **`provides.events`** declared (#1717) and **`provides.role`** declared (#1704).
- **Name-matched inputs** (#1825) with the engine resolving paths (#1826). The manifest declares only the artifact `id` and `required:` — **no producer stage, no path, no type** — and every path this plugin constructs in code is deleted. *(Amended 2026-08-12 by #1768: this read "`from:`-style inputs", i.e. the consumer naming its producer as `from: <stage>.<output_id>`. ADR-055 §1 removed that — the producer name is redundant given output-id uniqueness, and it could not express a backwards edge. Any `source: artifacts` or `source: cycle_feedback` input in this plugin becomes an ordinary name-matched input.)*
- **`cleanup`** (#1829) — if the plugin holds live resources, `release` frees them; if it has nothing to free, the hook is absent and that is recorded, not implied.

## Folds in

The aggregator is a **consumer** of the lens plugins, so it is where #1753's empty-array bug actually bites (still open: `plugins/agent/review-aggregator/plugin.sh:322` computes `all(. >= 7)` over an empty score list, which is `true`, so zero lenses reads `ready`). Under #1825/#1826 it declares what it consumes by name (`lens_result`) and the engine checks presence before dispatch — an absent lens result becomes a refusal to aggregate rather than a vacuous `ready`.

Sequence after the two lens migrations. *(Both have landed: #1840 review-lens and #1841 security-lens.)*


## The map-producer case this plugin owns (added 2026-08-19, refreshed 2026-09-29)

`review-aggregator` is the **only** consumer of a `map` group's output, so ADR-055 §1.4 —
*"when the producing stage is a `map` group, the consumer receives the set of its members'
outputs. This retires the `lens-*.json` wildcard in `review-aggregator` and the
corresponding exemption both checkers carry for it"* — lands here.

Where it stands on main:

- **Fixed:** the id mismatch. `plugins/agent/review-aggregator/manifest.yaml:87` now declares
  `id: lens_result`, matching the producer at `plugins/agent/review-lens/manifest.yaml:87`.
- **Fixed:** the engine side. A `map` producer resolves to a JSON array of its members' paths
  under the one input id (`core/pipeline/input-resolve.sh:18-23`), for the 6-element
  `review_lenses` group (`config/templates/simple.yaml:451`). No checker in `core/` or
  `scripts/lib/` carries a `lens-*.json` exemption any more.
- **Still open, and this migration's job:** the plugin never reads that array. It finds lenses
  itself — a roster lookup, then a `lens-*.json` glob fallback
  (`plugins/agent/review-aggregator/plugin.sh:138`, `:383-395`) — and does not read
  `ZBUILD_STAGE_INPUTS`. It must read the `lens_result` set the engine hands it, and the glob
  goes.

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
**In this plugin specifically.** `review_report_md` (`${artifact_dir}/review-report.md`) is declared `required: false` (`plugins/agent/review-aggregator/manifest.yaml:97`) while the comment directly above it argues the opposite:

> `#1986`: this stage suppresses the lens summaries it aggregates, so it **MUST** publish one itself — otherwise the roster's findings reach no prompt at all and the loss is silent.

The comment states the requirement and the failure mode; the contract line under it says the artifact is optional. If this file is ever absent, the suppressed lens summaries are gone and nothing reports it — precisely the silent loss the comment warns about. Aggregator suppression makes this the highest-consequence instance of the three, because absence here discards a whole roster's output rather than one stage's.

Note this plugin is also in scope for #1986 (roster declaration + engine-side suppression). That issue covers *which* summaries ship; it does not change `required:`, so the two do not overlap.
