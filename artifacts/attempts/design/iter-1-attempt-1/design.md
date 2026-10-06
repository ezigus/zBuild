# Design — Retire live `exhausted` disposition references (#2222)

## Decision summary

**Goal.** Replace every non-historical occurrence of `exhausted` as a disposition
word in comments, prose, and docs with the vocabulary standardised by #2187
(`out_of_turns` / `timed_out`); add dated backward-pointer notes in ADR text
that must retain the historical chain-of-custody.

**Context.** ADR-054 §6a (2026-09-25, #2187) retired `exhausted` from the
disposition set and replaced it with `out_of_turns` (turn budget hit) and
`timed_out` (wall-clock hit). All functional code was migrated in #2187 PR 2;
`lint-disposition-words.sh` (npm run lint) now rejects a literal off-set word
in executable paths. Six non-functional sites — one rc-table comment, one
plugin comment, one wiki paragraph, one issue body, and two ADR prose blocks —
still use the retired word in non-historical framing. Part 1 of issue #2222
(per-stage budget-note helpers for impact, security-lens, spec-coverage,
issue-acceptance) was shipped in #2252/#2253 and is not in scope here.

**Decision.** Six targeted prose/comment edits, no behavioral code change:

1. `dispatch-rc.sh` line 166 comment: `→ exhausted` → `→ out_of_turns (ADR-054 §6a, #2187)`
2. `review-lens/plugin.sh` line 379 comment: "Write disposition:exhausted" → "Write disposition:out_of_turns"
3. `review-report.md` line 137: `exhausted` → `out_of_turns`
4. `keepers-manifest.yaml` line 1430: `disposition: exhausted` escalates (ADR-054 §6) → `out_of_turns` escalates (ADR-054 §6a)
5. `ADR-054` line 163 rc=10 table row: add dated note `(superseded by §6a / #2187 — now out_of_turns)`
6. `ADR-001` line 163 historical retirement note: add inline note `(exhausted retired #2187; now out_of_turns)`

After all six, the R-4 acceptance grep finds `exhausted` only in:
- ADR-054 §6 original vocabulary table (~line 223) — superseded section header
- ADR-054 §6a history prose (lines 239, 258) — explicitly labelled as retired
- ADR-001 line 163 — inside the 2026-08-20 #1900 retirement note (with new pointer)
- `review-lens` line 382 `budget_exhausted` — a reason/detail argument, not a disposition word
- `core/` event names (`cycle.timeout_exhausted`, `router.budget_exhausted.retry`) and prose
  ("exhausted its turn budget") — English verb / compound event tokens, not the disposition word

```scope
core/pipeline/dispatch-rc.sh
plugins/agent/review-lens/plugin.sh
docs/wiki/plugins/review-report.md
.github/issues/keepers-manifest.yaml
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-001-plugin-contract.md
core/pipeline/disposition.sh
scripts/lib/lint-disposition-words.sh
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
tests/unit/stage-budget-note-test.sh
plugins/agent/impact/tests/impact-prompt-contract-test.sh
plugins/agent/review-lens/tests/review-lens-v2-budget-test.sh
tests/unit/exhausted-disposition-retired-test.sh
```

```acceptance
SPEC-1[done]: Every model-calling stage (including impact, security-lens, spec-coverage, issue-acceptance) renders a budget note whose wall-clock and turn-cap numbers come from the enforcing resolver functions, not hand-copied constants. covers: R-1 R-2 evidence: tests/unit/stage-budget-note-test.sh
SPEC-2[done]: impact's existing prompt-contract assertions pass unchanged. covers: R-3 evidence: plugins/agent/impact/tests/impact-prompt-contract-test.sh
SPEC-3[no-code]: Every non-historical occurrence of `exhausted` as a disposition label is removed or annotated with a dated backward-pointer note so the R-4 acceptance grep finds it only in explicitly historical text. covers: R-4
SPEC-4[done]: npm test and npm run lint are green after the six prose edits. covers: R-5 evidence: tests/unit/stage-budget-note-test.sh plugins/agent/impact/tests/impact-prompt-contract-test.sh
WIRING: none
TESTFILES:
SPEC-3: tests/unit/exhausted-disposition-retired-test.sh
```
