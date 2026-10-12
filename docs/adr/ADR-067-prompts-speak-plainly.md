# ADR-067 — Model-facing text speaks plainly

**Status:** Accepted (2026-10-03); amended 2026-10-05 (#2308, §8), 2026-10-07 (#1799, §8), 2026-10-11 (§8 findings wording, §9), 2026-10-12 (§8: the engine/stage prompt contract — three parts from the stage, three blocks from the engine, one order)
**Issue:** #2269, #2308
**Related:** ADR-066 (every ADR statement has a test), ADR-055 §9 (stage summaries are read by every later stage), ADR-036 (the acceptance check whose vocabulary leaked), ADR-050 §9 and ADR-068 §8 (each stage's latest output, any run), ADR-063 §1 (the budget is stated from the value that enforces it)

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
8. **Every stage prompt is six sections in one order: three from the stage, three from the engine** (amended 2026-10-05, #2308; rewritten 2026-10-12). It is a contract between the engine and every stage, whether or not the stage calls a model.
   - **The engine gives every stage three blocks**, written at dispatch by `plugin_hook_call` into the stage's blocks folder (`scripts/lib/stage-prompt.sh`, exported as `ZBUILD_STAGE_BLOCKS`):
     - **From the repo** — what the target repository says, read from its `.zbuild/` settings area and, failing that, from the zBuild install (never mixed; zBuild runs from its install on every repository, itself included): the repository's intent (`.zbuild/vision.md`, ADR-049), its rules (`.zbuild/prompts/rules.md`, else zBuild's default rules), and its guidance for this stage (`.zbuild/prompts/<stage>-overrides.md`, only when present, ADR-032). A repository file's own headings are pushed down so they never read as the prompt's sections.
     - **Previous work** — the latest output of every stage that has run, the stage's own included, whichever try or run wrote it (ADR-068 §8, ADR-050 §9): each stage's output paths, its summary in full up to its own cap (no stage is dropped to fit a total), its numbered findings (`- <stage> finding <n> (opened by <stage>): …`, ADR-068 §5), a failing stage's error output, the stage's own notes (another stage's notes are its working file, not its output, and are not listed — amended 2026-10-12), and what moved since it last ran — the repository files changed and whether the issue text changed. No engine framing is added; each stage's verdict is shown as the stage wrote it.
     - **Rules for this stage** — nothing later in the prompt can take away part of its own job; the read-only rule for a stage that may not change the repository; its notes file (every stage has one, `artifacts/notes/<stage>[-<element>].md`, written as it works and handed back under Previous work); its budget — seconds and turns per model call, the same for every stage, from the same resolvers the router enforces (`scripts/lib/stage-limits.sh`, ADR-063 §1) — the engine needs no word from a stage about whether or how it calls a model; and **How every stage works**: say in your own result what you did about each finding, say what you could not finish, do your whole job, and read data the way the code that writes it writes it — and make test data with that code, never by hand (#1799).
   - **A stage that calls a model writes only its own three parts** — `## What you own`, `## What you judge against`, `## What you must not do` — and composes its prompt with `stage_prompt_compose_parts` (or `stage_prompt_compose`). The library puts every prompt in the one order: From the repo, What you own, What you judge against, Previous work, What you must not do, Rules for this stage. No stage chooses the order.
   - **The engine never edits a stage's text.** Before every model call a dispatched stage makes, the router checks the order (`stage_prompt_check`) and refuses a prompt that breaks it (`router.prompt.refused`); it adds nothing — no vision preamble, no inputs, summaries or notes blocks, no per-call iteration header, diff or branch summary, and no inserted rule. A model call made outside any stage is not held to the contract. The one thing put before a stage's prompt is its persona, and only for a provider that cannot run the call as an agent: `## Who you are` and the persona's perspective (ADR-051 §3, amended 2026-10-12). No stage frames a persona in its own text.
   - Model-facing text never tells a stage to skip part of its own job ("is proven by the pipeline itself", "never judge it here", "not yours to", "keep every other entry"); it says what the stage owns instead. spec-coverage keeps its exemption for how a change is verified, worded as what it owns: it judges the behaviour before any code exists, and the check that compares the finished change with the issue judges the rest. test-author is told to check the new value or file itself, not only that the step finished without an error. (Amended 2026-10-07, #1799.) The shared part also tells every stage, in any repository: when work reads data another part of the code writes, open the code that writes it and use the names and shapes it really produces, and when it produces them; a test that needs such data makes it with that code, not by hand; and a stage judging a change checks this too. #1799's change read a field the engine never writes, and its test passed because it wrote that field itself.
9. **A solution the issue proposes is a starting point, not the answer** (amended 2026-10-11). The plan and design prompts say: a section of the issue that records a decision (for example "Decision:") is binding; anything else it proposes — an approach, a file list, a scope, a claim that some files or tests are unaffected — is checked against the code, and the stage comes up with its own approach and says where it differs. #1668's issue said which tests the change left alone; it was wrong, the plan trusted it, and the first build round was spent blocked on files outside its scope.

## Consequences

- `scripts/lib/lint-plain-prompts.sh` (in `npm run lint`) reads the model-facing text in `config/model-facing-sources.txt` and refuses internal check names, ADR numbers and `_TPL_*` internals. A file that starts building model-facing text is added to that list.
- Since #2308 the lint also refuses text that tells a stage to skip part of its own job (§8).
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
- §1 (build's stop rule names the section earlier stages arrive in, never a retired marker) → `tests/unit/build-prompt-summary-marker-test.sh` M1–M3, M5, M6 (#2292)
- §7 (review lens) → `tests/unit/review-lens-requirements-plain-test.sh` L1–L4
- §8 (the library composes the six sections in the one order, refuses without the engine's blocks or with an empty part, and the check rejects a missing or out-of-order section) → `tests/unit/stage-prompt-contract-test.sh` K1–K5
- §8 (From the repo: the target repository's `.zbuild/` vision, rules and stage guidance, else zBuild's default rules; no guessing at the repository's layout) → `tests/unit/stage-prompt-contract-test.sh` F1, F2
- §8 (Previous work: every stage's latest output including its own, an earlier run's too, no framing, nothing dropped to fit, findings and errors, completion order, an aggregator and its members, what moved) → `tests/unit/stage-prompt-contract-test.sh` P1–P8
- §8 (Rules: the own-job rule, read-only only for a non-writer, the notes file, the same per-call budget for every stage from the enforcing resolvers, how every stage works) → `tests/unit/stage-prompt-contract-test.sh` R1–R3
- §8 (every stage gets the three blocks at dispatch, a map element its own; the engine refuses no stage over a missing output) → `tests/unit/stage-blocks-dispatch-test.sh` D1–D4
- §8 (every model-calling stage sends a prompt in the contract order with the engine's blocks in their sections; every one has a composer) → `tests/unit/prompt-contract-every-stage-test.sh` E1–E3
- §8 (no stage frames a persona; for a provider that cannot take an agent, `## Who you are` comes before the contract prompt) → `tests/unit/prompt-contract-every-stage-test.sh` E5; `tests/unit/persona-agent-delivery-test.sh` PA5
- §8 (the From the repo cache is written whole or not at all) → `tests/unit/stage-prompt-contract-test.sh` F4
- §8 (the router adds nothing and refuses a stage prompt out of order, in a single call and in a loop, saying why; a call outside a stage is not held to it) → `tests/unit/router-prompt-contract-test.sh` RC1–RC5
- §8 (every call of a stage's model loop sends the stage's prompt unchanged) → `tests/integration/route-loop-prompt-unchanged-test.sh` LP1, LP2
- §8 (no stage declares whether it calls a model; a stage's own notes come back to it and no other stage's notes are listed) → `tests/unit/save-as-you-go-test.sh` C1, C3; `tests/unit/retired-impact-review-report-inputs-test.sh` RT5
- §8 (test-author checks the new value itself) → `tests/unit/prompt-contract-every-stage-test.sh` T1
- §8 (read data the way its writer writes it; make test data with that code) → `tests/unit/prompt-contract-every-stage-test.sh` E4
- §8 (no text tells a stage to skip part of its job) → `scripts/lib/lint-plain-prompts.sh`, tested by `tests/unit/lint-plain-prompts-test.sh` P10–P11
- §8 (spec-coverage's reworded exemption) → `tests/unit/spec-coverage-test.sh` SPEC-7, SPEC-9
- §8 (findings: say in the result what was done) → `tests/unit/engine-keeps-only-stage-outputs-test.sh` K5
- §9 → `plugins/agent/plan/tests/plan-test.sh` (Test 3c2, plan); `tests/unit/resume-default-test.sh` (the ADR-067 §9 assertions on design's prompt)
