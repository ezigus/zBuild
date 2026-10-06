[Phase 0/G] every model stage is told its real limits, and the retired `exhausted` word is gone from live text

Part of #1819. Split out of #2032 on 2026-09-28. #2032 keeps the part that changes how cycles decide they are done (By-hand). This issue holds the two parts that don't depend on it.

**Build Mode: Dogfood** — ADR-057 gate 4: prompt text and comments/docs only; nothing that reads verdicts or dispositions, and no template or roster change.

## 1. Tell the remaining model stages their real limits (ADR-063 §1)

ADR-063 §1: a stage's prompt states its turn and wall-clock budget, **rendered from the same values the engine enforces** (`_route_resolve_timeout` / `_route_resolve_max_turns`, `core/router/route.sh`), never a hand-copied number.

Already done this way: design, monitor, plan, review-lens, review-report, test-author, spec-correspondence (each has a `_<stage>_budget_guidance` helper).

Still missing:

| stage | today |
|---|---|
| `impact` | hand-written "BUDGET DISCIPLINE" prose (`plugins/agent/impact/plugin.sh:218`) — keep the wording, change only where the numbers come from |
| `security-lens` | no budget block |
| `spec-coverage` | no budget block |
| `issue-acceptance` | no budget block |

Follow the existing per-stage helper pattern (e.g. `_review_lens_budget_guidance`). **Coordinate with #1838** (impact → v2) — if that PR is open, add the `impact` block there or rebase onto it rather than editing the same prompt twice.

## 2. Retire the last live references to `exhausted` as a disposition

#2187 (closed 2026-09-25) retired `exhausted`; the words are now `timed_out` / `out_of_turns` (response: retry). These still describe it as current:

| where | what |
|---|---|
| `core/pipeline/dispatch-rc.sh:159-168` | comment table says `10 → exhausted "more budget, or the work must shrink"` and quotes pre-#2187 responses; the code below maps `10 → out_of_turns` |
| `plugins/agent/review-lens/plugin.sh:331` | comment: "Write disposition:exhausted and propagate rc=10"; the code writes `out_of_turns` |
| `plugins/agent/review-report/plugin.sh:166` | comment cites `exhausted` |
| `docs/wiki/plugins/review-report.md:137` | "`disposition` is `complete`, or `exhausted` when…" |
| `.github/issues/keepers-manifest.yaml:1430` | "`disposition: exhausted` escalates (ADR-054 §6)" |
| `docs/adr/ADR-054-stage-contract.md:154` | §4 rc table: `10 scope_too_large → exhausted` — add a dated pointer to §6a (`out_of_turns`) |
| `docs/adr/ADR-001-plugin-contract.md:163` | "`escalate` → `exhausted`" — add a dated pointer to #2187 |

Text that is explicitly historical stays (ADR-054 §6 as amended by §6a, `core/pipeline/disposition.sh:27`). ADR-063 itself is amended in #2032, not here. `scripts/lib/lint-disposition-words.sh` already rejects `exhausted` as a code literal; this is the prose it cannot see.

## Out of scope

- A stage that didn't finish ending its cycle, and gates reporting why a model call stopped — #2032.
- ADR-063 amendment — #2032.

## Acceptance

Write the red first; state in the PR body the assertion and how it failed.

- [ ] **Red first:** for each of `impact`, `security-lens`, `spec-coverage`, `issue-acceptance`, a test that sets the resolved `timeout_s` / `max_turns` to distinctive values and asserts the prompt contains them. Fails at the merge-base (no block, or a hand-copied number).
- [ ] Changing the resolved values changes the rendered numbers (proves they are not hand-copied).
- [ ] `impact`'s existing prompt-contract assertions (`plugins/agent/impact/tests/impact-prompt-contract-test.sh`) still pass.
- [ ] `/usr/bin/grep -rnE 'exhausted' core plugins scripts docs/wiki .github/issues docs/adr/ADR-001* docs/adr/ADR-054*` finds `exhausted` as a disposition only in explicitly historical text.
- [ ] `npm test` and `npm run lint` green.

Refs ADR-063 §1, ADR-054 §6a, ADR-057, #2187, #2032, #1838, #1819.

## Additional context from issue comments

The budget-note half is done in #2253 (merged): a shared note from the values the router enforces now reaches issue-acceptance, security-lens, spec-coverage, spec-correspondence and impact, and build's note gained the ~70% finish target; tests/unit/stage-budget-note-test.sh guards every model-calling stage. The retired `exhausted` wording half remains open here.
