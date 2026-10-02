[Phase 0/F] migrate the pr-delivery plugin to contract v2

> **Updated 2026-09-29** (Initiative 1.3 alignment audit, main 900db6b0): #1799 is now listed as related rather than folded in (pr-open already writes v2, so the draft fix does not depend on this migration); retry and `primary: true` wording refreshed.

Part of #1819 (Phase 0 — the stage↔engine contract). Member of the **F set** — one plugin per PR, each independently verifiable.

Migrate `plugins/agent/pr-delivery` to contract v2. The engine reads v1 and v2 side by side (#1824), so this plugin moves on its own and nothing else has to move with it.

## What this plugin adopts

- **v2 result file** (#1821) — `result_contract: 2`, and mandatory `verdict`, `disposition`, `reason`. Anything this plugin currently communicates through a sidecar, an event, or a bare exit code moves into the result; plugin-specific detail goes under `data`, namespaced.
- **`disposition`** (#1822) — the plugin declares *how* it stopped. It no longer decides its own retry policy: the engine's response table (`core/pipeline/disposition.sh`) decides whether a word retries, and the template's per-stage `retry:` sets how many times (`_runner_retry_budget`, `core/pipeline/runner.sh`). Use the ADR-054 §6a words; a model-call failure is named by `router_reason_disposition` (`scripts/lib/router-rc-classify.sh`), not by the plugin.
- **rc ∈ {0,1}** (#1823) — every other exit code this plugin returns today is expressed as a `disposition` instead.
- **`valid_verdicts`** declared in the manifest and enforced (#1708) — a verdict outside the declared set becomes a structural failure.
- **Router budgets** in the manifest (#1816) rather than resolved only from the template.
- **A `primary: true` output** declared in the manifest. Prerequisite for #1850: `no primary declared -> pass` cannot be flipped until every dispatched stage has one (34 of 56 manifests do today; the rest are personas and role-resolved backends). This plugin already declares one (`plugins/agent/pr-delivery/manifest.yaml:59`), so this item is already met.
- **`provides.events`** declared (#1717) and **`provides.role`** declared (#1704).
- **Name-matched inputs** (#1825) with the engine resolving paths (#1826). The manifest declares only the artifact `id` and `required:` — **no producer stage, no path, no type** — and every path this plugin constructs in code is deleted. *(Amended 2026-08-12 by #1768: this read "`from:`-style inputs", i.e. the consumer naming its producer as `from: <stage>.<output_id>`. ADR-055 §1 removed that — the producer name is redundant given output-id uniqueness, and it could not express a backwards edge. Any `source: artifacts` or `source: cycle_feedback` input in this plugin becomes an ordinary name-matched input.)*
- **`cleanup`** (#1829) — if the plugin holds live resources, `release` frees them; if it has nothing to free, the hook is absent and that is recorded, not implied.

## Folds in

pr-delivery is where a wrong verdict becomes visible to a human, so the v2 result matters here. Its primary output today is `pr-url.txt` (`plugins/agent/pr-delivery/manifest.yaml:55-59`), which carries no verdict, disposition or reason.

**Related, not folded in:** #1799 (a failed or unconverged run still opens a non-draft PR, and the PR body never shows convergence; #1724 was merged into it). That fix is independent of this migration: the tool plugin that opens the PR, `plugins/tool/pr-open`, already writes v2 results (`plugins/tool/pr-open/plugin.sh:213`, `:283`, `:444`), and the draft decision and the body are built there (`:316-339`). *(History: this section said this issue "provides the mechanism" #1799 and #1724 need. It does not.)*

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

## Additional context from issue comments

**Fold in #2250** (found 2026-10-01 while reworking the parity fixture for #1842). It lives in this plugin:

- When `pr-open` refuses for lack of a review signal, it writes `verdict: blocked` and returns 0.
- `pr-delivery` then writes `pr-delivery-summary.md` as **"pass — delivered the change by delegating to the pr-open stage"**.
- The stage fails only afterwards, on a missing `pr-url.txt`.

This migration makes `pr-delivery` write its own v2 result, so it must read `pr-open`'s verdict, not only its exit code.

**Additional acceptance:**
- [ ] Red first: with no review report, the `pr` stage's result and summary say no PR was opened and name `review_signal_missing`. Today: "pass / delivered", then `plugin.artifact.missing` for `pr-url.txt`.

#2250 closes with this issue.
