[Phase 0] every stage publishes a summary and following stages ingest them — advisory included

Answers #1898 and generalises it: **every stage publishes a summary, and every following stage ingests them — advisory included.**

#1976 built the mechanism and #1977 declared the first three producers, but the collector filters on `convergence: gate`. That filter was deliberate — it kept #1898's open question from being answered by accident. #1898 is now decided: advisory output *does* reach downstream prompts.

## Why this does not weaken ADR-040 §5

§5's machine-enforced invariant governs whether a stage may **block** — whether it can appear in a must-pass set or an `exit_when` predicate. Injecting a stage's text into a prompt places it on no convergence path. The B5 no-LLM-on-the-convergence-path invariant is untouched: advisory stages still never gate.

## The duplication problem this must solve

If every stage publishes a summary *and* an aggregator publishes its merged rendering of those same stages, the prompt carries both. That is precisely the contradiction #1979 removed — the same text twice, once framed "resolve every finding", once framed "context".

So an aggregator declares that it **covers a roster**. The engine then ships only the aggregate and suppresses the roster members' own summaries. Flip the flag off and the members flow individually. Duplication is removed by construction, not by convention.

**The real work is the roster, not the flag.** `gate-aggregator` discovers its roster at runtime from cycle members whose manifest declares `convergence: gate` (`_ga_build_roster`, excluding itself). The summaries collector walks `.stage_statuses` and knows nothing about rosters. The resolution has to be available at collection time — lifted into a shared helper, or declared.

## Scope

- Drop the `convergence: gate` filter in `_summaries_stage_summary_path` (`core/pipeline/input-resolve.sh`).
- `tests/unit/summary-producers-test.sh` SPEC-4 currently **fails** if a non-gate plugin declares a summary. It asserts the opposite of this decision and inverts.
- Add summary outputs to stages that lack one, so "every stage" is true rather than aspirational.
- Aggregator roster declaration + engine-side suppression, for both `gate-aggregator` and `review-aggregator` (same shape on the advisory side).
- Amend ADR-040 §4 with the decision and its reason — #1898's own acceptance criteria ask for exactly this.
- Re-check the prompt budget against ADR-029's `context_budget`: ~14 agent stages contributing instead of 3. Confirm the per-summary (~4KB) and total (~24KB) caps still hold **against measured numbers**, not assumption.

## Acceptance

- [ ] An advisory stage's summary reaches a downstream agent prompt.
- [ ] A roster-covering aggregator's members are suppressed; only the aggregate ships. No content appears twice.
- [ ] With the flag off, members flow individually.
- [ ] Latest-wins per stage still holds — the block stays flat in stage count, never iteration count (ADR-029).
- [ ] Total injected size measured and within `context_budget`.
- [ ] ADR-040 §4 records the decision; §5 unchanged.
- [ ] `npm test` and `npm run lint` green. Reddens at the merge-base.

Closes #1898. Refs #1976, #1977, #1979, ADR-040 §4/§5, ADR-029.
