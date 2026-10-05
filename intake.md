[Phase 0/H] closeout: ADR-028 and its guard test still say review-lens and review-report are unmigrated — the code migrated in #1840/#1843

Part of #1819.

> **Rewritten 2026-09-28.** The code fix landed inside the v2 migrations, as this issue planned: `review-lens` in #1840 (PR #2165) and `review-report` in #1843. What is left is the **record**: ADR-028 still says neither stage is migrated, and the guard test meant to catch that disagreement takes the wrong branch. This issue is now that closeout.

**Build Mode: Dogfood** — ADR-057 gate 4: an ADR paragraph and a docs guard test; nothing on the grading path.

## Done (verified 2026-09-28)

| | evidence |
|---|---|
| `review-lens` parses through the shared gate | `plugins/agent/review-lens/plugin.sh:357` — `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok` |
| `review-report` parses through the shared gate | `plugins/agent/review-report/lib/lenses.sh:162` — `_llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok` |
| a valid envelope + brace-bearing sign-off is recovered | `tests/unit/review-report-v2-contract-test.sh` SPEC-8 (`_RR_REPLY_MODE=signoff`), and the `review-lens` v2 result test |
| a genuinely unparseable reply still fails visibly | same SPEC-8 (`garbage` → `review_report.lens.unparseable`) |

## What is left

**1. ADR-028 says the opposite of the code.**
`docs/adr/ADR-028-shared-llm-agent-framework.md:189` — "`review-lens` and `review-report` are **not** migrated: both still call bare `extract_first_json_object`…" — and `:193` — "`review-lens` was **not** migrated". Both are now false. Amend §Migration: list `review-lens` and `review-report` alongside `plan`, `security-lens`, `monitor`, with a dated note citing #1840/#1843, and add their schema gates to the "Per-stage gates added" list. Keep the 2026-09-02 correction note — it is history.

**2. The guard checks the claim against a comment, not the code.**
`tests/unit/adr-migration-claims-test.sh`:
- **SPEC-3** (`:74`) greps `review-lens/plugin.sh` for `extract_first_json_object`. The only hit is a *comment* (`plugin.sh:353`, explaining why the shared parser is used), so the test still takes the "not migrated" branch and passes for the wrong reason. Match code lines only (exclude `#` comment lines).
- **SPEC-2** (`:55`) checks only `plan security-lens monitor`. Add `review-lens` and `review-report`, and search the plugin directory's non-test `.sh` files — `review-report`'s parser lives in `lib/lenses.sh`, not `plugin.sh`, so a `plugin.sh`-only check would report it unmigrated.
- The file's header comment still describes `review-lens` as the unmigrated counter-example; update it.

## Acceptance

Write the red first; state in the PR body the assertion and how it failed.

- [ ] **Red first:** SPEC-3 asserts the *migrated* branch for `review-lens` — fails at the merge-base because the comment at `plugin.sh:353` matches.
- [ ] SPEC-2 covers `review-lens` and `review-report` and passes against the code as it is.
- [ ] Negative control: re-introducing a bare `extract_first_json_object` **call** (not a comment) in either plugin turns SPEC-2 red.
- [ ] ADR-028 names both stages as migrated; no sentence in it says otherwise.
- [ ] `npm test` and `npm run lint` green.

Refs ADR-028, ADR-060, #1840, #1843, #2034, #2037.

## Additional context from issue comments

Reopened — closed in error. PR #2037 fixed the **ADR text** that concealed this gap; the code is unchanged. `plugins/agent/review-lens/plugin.sh:224` still calls bare `extract_first_json_object`, so a reply carrying a valid envelope plus a brace-bearing postamble is still discarded rather than recovered.

My fault: PR #2037's body opened with "Closes #2035's sibling half" and GitHub parsed the `Closes #2035` out of it. The sibling half was the documentation; this issue is the code.

---

## Sequencing: Initiative 1.3 / Phase 0, after [Phase 0/F]

Filed into **Initiative 1.3 / Phase 0** as **[Phase 0/H]**, sequenced after the contract-v2 migration.

Note that **#1840 (review-lens) and #1843 (review-report) are already in [Phase 0/F]** — both are on the v2 migration list. This issue is the parsing half of the same two plugins, so doing it *with* their F migration is cheaper than doing it before or after: one pass over each plugin instead of two.

The parser change itself has no hard v2 dependency — `_llm_envelope_parse --schema-gate` works at v1. The reason to hold it is scheduling, not blocking.

### What stays true while it waits

`review-lens` fails **visibly**, which is why this costs findings rather than correctness. On an unparseable reply it emits `review_lens.unparseable` and writes a summary saying the lens reviewed nothing, with "Absence here is not evidence of a clean change." Nothing silently reads as clean.

The cost is a recoverable reply being thrown away — `extract_first_json_object` is LAST-wins, so a model that emits its envelope then appends a brace-bearing postamble loses the whole review pass, where `plan`, `monitor` and `security-lens` would recover it.
