# ADR-067 — Model-facing text speaks plainly

**Status:** Accepted (2026-10-03)
**Issue:** #2269
**Related:** ADR-066 (every ADR statement has a test), ADR-055 §9 (stage summaries are read by every later stage), ADR-036 (the acceptance check whose vocabulary leaked)

## Context

Text the engine sends to a model is read literally, and any engine word in it is read in its everyday sense. In #2032 run 37066151065:
- design listed a list of event names as `WIRING` (the engine meant "the existing file whose code calls the new behaviour");
- the acceptance check fed back "WIRING … inert — reverting it breaks no TESTFILE";
- test-author answered with a test that greps the file, satisfying the measure rather than the intent.

The 2026-10-03 audit found the same pattern in about 15 places: check names in feedback (NEGCTL, REACHABILITY, tautology), maintainer notes in prompts (ADR numbers, "legacy", a template that no longer exists), examples that broke their own rule, and a stage told to do something its permissions forbid.

## Decision

1. **Never name an internal check, label or code in model-facing text.** Say what the model must do, or ask the question the label stands for. A key the parser reads (`WIRING:`, `TESTFILES:`, `LOOP_COMPLETE`) may stay if the plain question sits beside it.
2. **Feedback is "what was tried → what happened → what to change"**, in words the reader was already given. Raw verdict lines and snake_case reasons stay in machine-read files (result JSON, summaries parsed by the engine) and never reach a model as feedback.
3. **Examples obey the rule they illustrate.**
4. **One word means one thing across all prompts** ("guard", "wiring", "scope", "baseline").
5. **No notes for maintainers in prompts** (ADR or issue numbers, "legacy", "do not edit") **and no repo internals** (`_TPL_STAGES`, real paths of this repo where the prompt runs against others).
6. **Never tell a stage to do something it may not do** (build is not asked to tag tests it may not edit).
7. **Every stage receives all findings**, rendered readably, and decides for itself whether it can act. Text is not filtered by stage.

## Consequences

- `scripts/lib/lint-plain-prompts.sh` (in `npm run lint`) reads the model-facing text in `config/model-facing-sources.txt` and refuses internal check names, ADR numbers and `_TPL_*` internals. A file that starts building model-facing text is added to that list.
- Rules 2–7 are applied in review; the tests below pin the rewritten texts so they cannot drift back.

## Implementation Notes (#2269)

- The lint reads heredoc bodies, `stage_summary_write` calls, the acceptance check's `clauses+=(` lines, `printf` lines for files listed with `printf`, and whole prompt `.md` files. It ignores variable names (a model sees values, not names) and heredocs opened with `# not-model-facing`.
- Rewritten: design's acceptance section, the acceptance check's feedback, the design check's feedback (codes stay in its result JSON), shape-floor's summary, test-author's tag lines, build's acceptance lines, the summaries framing later stages read, review-lens's requirements, impact, plan, the security lens prompt, the product-owner persona and the repo-rules wording.

## Enforced by

- §1, §5 → `scripts/lib/lint-plain-prompts.sh`, tested by `tests/unit/lint-plain-prompts-test.sh` P1–P7
- §1, §3 (design) → `tests/unit/design-wiring-guidance-test.sh` G1–G4
- §2 (acceptance check) → `tests/unit/acceptance-feedback-plain-test.sh` F1–F4
- §2 (design check) → `tests/unit/design-gate-feedback-plain-test.sh` D1–D3
- §2 (shape check) → `tests/unit/shape-floor-summary-plain-test.sh` S1–S3
- §6 (build) → `tests/unit/build-prompt-spec-text-test.sh` P1–P2
- §1 (build's stop rule names the real summary heading, never a retired marker) → `tests/unit/build-prompt-summary-marker-test.sh` M1–M6 (#2292)
- §7 (review lens) → `tests/unit/review-lens-requirements-plain-test.sh` L1–L4
