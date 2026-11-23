# ADR-073 — A requirement and its test are written as Given/When/Then, and every part is judged

**Status:** Accepted (2026-11-04); amended 2026-11-22 (#2586, §5: design writes the behaviour a requested test proves, never a test step — `Steps: test`; a step's numbered parts, one file each); amended 2026-11-22 (#2584, §5: the decisions are judged for outside assumptions — `Decision: unhandled`); amended 2026-11-20 (#2571, §5: design's check judges every question the design carries, as one more part — judged again when the issue's text changes; one it leaves unjudged stays open and fails no try; design drops none the check did not retire); amended 2026-11-20 (#2569, §5 §6: every refusal says what would be accepted — ACCEPTED IF, written by the check; INSTEAD becomes ACCEPTED IF; design's and test-author's findings carry the check's own words, not the engine's advice); amended 2026-11-16 (#2555, §5: every problem the check finds names the line it is about; outside is not-asked); amended 2026-11-04 (#2470, §1 §2 §5 §6: a SPEC is shown with its parts as design wrote them; design is told which SPECs it keeps are still on one line; a finding shows the failing SPEC whole, marked where to fix it; the checks answer per SPEC); amended 2026-11-05 (#2474, §6: an untestable SPEC ends the round; the check sees the section headings)
**Issue:** #2467 (#1805 run 41757933766)
**Amends:** ADR-031 (the form of a SPEC), ADR-069 §1 (a [code] or [done] SPEC has parts), ADR-072 §3 (the checks answer a line per part), ADR-036 (build's three ways with a test that leaves something behind)
**Related:** ADR-068 §3 (a `misconfigured` result ends the run), ADR-071, ADR-066 (every ADR statement has a test)

## Context

On #1805 run 41757933766, test-author used all three of its tries on two SPECs:
- **BNDY-1** said a test file "contains both a resume-side assertion and a fresh-run sub-case". That describes a file, not a behaviour.
- **DLGT-1** bundled two behaviours and a sentinel into one SPEC.

design's own check had passed both. test-author's check called each test "partial" three tries running, without saying which part was missing. test-author cannot change a SPEC, and sending one back from test-author to design would loop the stages. So a SPEC has to be testable when design writes it, and every check has to say exactly which part of it falls short.

## Decision

1. **A SPEC's parts.** A SPEC keeps its first line: id, status, title, `covers:`, `evidence:`. Its behaviour goes on indented lines under it:
   - `Given:` the setup. Optional, any number.
   - `When:` the one action. Exactly one.
   - `Then:` something a test can observe after the When. At least one.
   - `And:` continues the Given, Then or Cleanup above it.
   - `Cleanup:` what must be true again after the test, for what the Given sets up or a Then says happens that outlives the test's own sandbox. The test harness cleans up everything else, for every test.

   Which SPECs need them:
   - A `[code]` or `[done]` SPEC has parts. A `[no-code]` one may.
   - A SPEC from an earlier design written on one line still reads everywhere; design rewrites it with its parts when it keeps it.
   - Assertion tags do not change.

   The parts are labelled inside the engine: `Given 1`, `When`, `Then 2`, `Cleanup 1`. (Amended 2026-11-04, #2470: no model is shown these labels; see the amendment below.)

2. **How the parts are read.** The parser (`extract_acceptance_block`) keeps a SPEC's parts with it, apart from its words, so every reader still sees one entry per SPEC, and its title, `covers:` and evidence read as before.
   - `acceptance_spec_parts_v` gives the labelled parts.
   - `acceptance_spec_render_v` and `acceptance_block_render_v` show a SPEC with its parts to a model.
   - test-author, its check, build, issue-acceptance and the review lenses see each SPEC with its parts.
   - The run-status comment and the summaries show the title only.

3. **design's scripted check (C10).** It refuses, in plain words:
   - a `[code]` or `[done]` SPEC with no parts;
   - one with no When, more than one, or an And straight after the When (a second action);
   - one with no Then;
   - an empty part;
   - a part line under no SPEC, or under a `REMOVED` line.

4. **The test's layout.** test-author writes each SPEC's test in sections marked by comments in the test's own language: Given, When, Then and Cleanup. A test it touches that is not laid out this way — one it updates, or one it adds an assertion to — it rewrites into the sections.

5. **design's check judges every part.** Besides one line per requirement and per SPEC, it answers one line per part: `<id> <part>: ok`, or one of:
   - `untestable` — a Then a test cannot observe (only for a Then);
   - `how` — says how it is built, not what it does;
   - `contradicts` — cannot be true together with another SPEC, the issue or an ADR;
   - `duplicate` — the same action as another SPEC (only for a When).

   On the SPEC's own line, `needs_cleanup` says the Given or a Then leaves something behind that no Cleanup puts back. Every complaint is quoted and checked (ADR-072 §3). Each finding names the SPEC, the part, what is wrong and why.

6. **test-author's check judges every part.** It answers one line per part — is each Given set up, the When done, each Then asserted, each Cleanup put back: `ok`, `missing` or `wrong`, with why and a quote of the part — and one line for the test's sections.
   - Each gap is a finding naming the SPEC and the part.
   - A part with no line is asked again on its own, then the SPEC is not judged.
   - A SPEC no test can prove (`<id>: untestable`) ends the loop's round (amended 2026-11-05, #2474; was: ends the run, `misconfigured`): test-author's result is `fail` with `ends_round`, naming the SPEC and why, as design's to rewrite, and the loop goes round to design (ADR-068 §3).

7. **build and a test that leaves something behind (ADR-036).** build never edits an acceptance test. Its prompt names three cases:
   - its code leaks — it changes the code to write where it is told;
   - the code is meant to leave something and the test does not clean it up — it answers `the test is wrong: <test file>: needs cleanup of <what>`, which reaches test-author (#2441);
   - every test needs the same guard — it changes the shared test helpers.

## Consequences

- A SPEC that is not one observable behaviour is refused when design writes it, by script (no When, two Whens) or by the judge (an unobservable Then), not after test-author has used its tries.
- A finding says which part is missing, so the stage that fixes it knows what to change.
- Designs and tests are longer: a SPEC is now several lines.

## Implementation Notes

- **Parsing:** `scripts/lib/acceptance-block.sh` — `_ACCEPTANCE_PART_RE`; `extract_acceptance_block` joins a SPEC's parts to it with a unit separator; `_acceptance_spec_line` sets `_ACC_SPEC_PARTS`; and `acceptance_parts_v`, `acceptance_spec_parts_v`, `acceptance_spec_render_v`, `acceptance_block_render_v` read and show the parts.
- **The part line in a reply:** `scripts/lib/reply-units.sh` treats a line like `FRSH-1 Then:`, `FRSH-1 And:` or an old `FRSH-1 Then 2:` as the start of an item.
- **design:** `plugins/agent/design/lib/checks.sh` (C10: `_dck_parts`, `_dck_plain`) and `plugins/agent/design/lib/coverage.sh` (`_dcov_part_line`, `_design_coverage_findings`); the prompt in `plugins/agent/design/plugin.sh`.
- **test-author:** `plugins/agent/test-author/lib/correspondence.sh` (`_sc_judge`, `_ta_correspondence`) and `correspondence-prompt.sh` (`_sc_batch_prompt`, since #2569); `plugins/agent/test-author/plugin.sh` (the parts in its prompt, the sections, and a `misconfigured` result for a SPEC no test can prove).
- **Other readers:** build (`plugins/agent/build/lib/context.sh`, `plugins/agent/build/lib/prompt.sh`), issue-acceptance (`acceptance_requirements_for_judge`), and the review lenses (`_rl_requirements_readable`).

## Amendment 2026-11-04 (#2470) — parts as written, findings marked where to fix, answers per SPEC

On #1805 run 41845438073 design used its three tries and never reached test-author. Try 1 kept nine one-line SPECs from the old design, which only the failing check named. The findings named parts `Then 1` and `Then 2`, labels design never wrote, so it could not tell which line was meant. Each finding was shown twice, in design's result and again in its summary.

- **§1: design is told up front which kept SPECs are still on one line.** When design refines its latest design, its prompt lists each `[code]` or `[done]` SPEC of that design written on one line (`- <id>`) and says each one it keeps is rewritten with its parts. A `[no-code]` SPEC is not listed.
- **§2: a model sees the parts as design wrote them.** Every SPEC shown to a model — to design's check, test-author and its check, build, issue-acceptance and the review lenses — shows each part by the word its line starts with: `Given:`, `When:`, `Then:`, `And:`, `Cleanup:`. It never shows a number (`acceptance_parts_shown_v`). The numbered labels stay inside the engine, to tell the parts apart.
- **§5 §6: a judge names a part by its word and a quote.** A part line is `<id> <word>: <verdict> | WHY: … | QUOTE: "<that part's own words>"`. The quote says which line it means: for `Then`, any Then or an And under one; for `And`, any And; for `When`, the When. A quote in none of them makes the answer unusable, asked again saying so. An old numbered label (`Then 2`) is still read. For every verdict the quote is the part's own words: `contradicts` and `duplicate` say in WHY what the part clashes with.
- **§5 §6: one line for a SPEC that is fine, one per thing wrong.** design's check answers `<id>: ok` for a SPEC with nothing wrong, and otherwise one line for each thing wrong, with no ok line. test-author's check answers `<id>: ok` for a SPEC whose test is right, and otherwise one line per part it falls short on, `<id> sections: missing` for a test not laid out in sections, or `<id>: untestable`. A SPEC with no line at all is asked again, naming it.
- **§5 §6: a finding is the SPEC whole, marked where to fix.** A SPEC with something to fix is one finding: a header (`FRSH-1: 1 part to fix`), the SPEC's first line as written, and each part as written, one per line. Each line to fix ends with `[FIX IN DESIGN: <why> — <what to do>]` or `[FIX IN TEST: <why> — <what to do>]`. A verdict about the whole SPEC (`outside`, `done_wrong`, `needs_cleanup`, missing sections) marks its first line. A SPEC no test can prove is marked `[FIX IN DESIGN: …]` on the line no test can prove. A requirement no SPEC covers is one line, marked `[FIX IN DESIGN: add or widen a SPEC so it covers this]`. A SPEC that passed is not shown. The finding's lines reach the next stage as one finding with several lines (`stage_findings_json` joins them on a record separator), and Previous work shows each of its lines (ADR-067 §8).
- **One place for each finding.** design's summary no longer copies its findings: it says they are in design's result (ADR-055 §9 amendment, #2470).

## Amendment 2026-11-05 (#2474) — §6: untestable ends the round; the check sees the sections

- **An untestable SPEC ends the loop's round, not the run.** test-author's result is `fail` with `data.ends_round: true` (ADR-068 §3), so design, the loop's first stage, rewrites the SPEC in the next round.
- **The check is shown the section headings.** The test file it reads (`acceptance_testfile_source`) keeps each comment line whose first word is Given, When, Then, And or Cleanup, in any case or formatting; every other comment is still left out, so a comment cannot stand in for code. #1805 run 42090130741 was asked about sections it could not see: they were stripped with the other comments.
- **The sections question is whether each part's code is under its own heading.** A `sections: missing` line may quote the test (`<test file>:"<line>"`); a quote given is checked like any other.

## Amendment 2026-11-14 (#2543) — §1 §5 §6: a requirement describes the code; the test is the test's

On #1700 run 43617030653 design wrote "ZBUILD_PLATFORM=macos is exported before scripts/lib/compat.sh is sourced" and "the stat probe module variable is inspected" — steps of a test, the first impossible on Linux — and test-author's check held its tests to them. §1 called a Given "the setup" and gave design a `Cleanup:` part, so design was writing the test. The reason in the Context — test-author could not send a SPEC back — no longer holds (ADR-068 §3, `ends_round`).

- **§1: a Given is the situation the code is in before the When, never the steps a test takes to get there; a Then is what can be seen, never how a test looks for it.** There is no `Cleanup:` part: how a test sets something up, checks it and cleans up after it is the test's. Design's checks refuse a `Cleanup:` part (`GWT_CLEANUP`). A SPEC from an earlier design that has one still reads.
- **§5: design's check has no `needs_cleanup`;** its `how` covers a part that says how a test sets something up or checks it, and the finding says to name the situation, the action or what can be seen.
- **§6: test-author's test puts back what it changes outside its own sandbox** — an exported variable, a file outside its folder, global config or git state — under its Cleanup section, and its check judges that from the test: `<identifier> cleanup: missing | WHY: … | QUOTE: <test file> | <line>`, a finding on the test.

## Amendment 2026-11-16 (#2555) — §5: one form for every problem the check finds

On #1764 run 43772987273 design's check wrote `DSCLA-10 Then: outside`: a part's line, on a verdict whose form named no part. The answer was refused twice and thrown away, and design was told only "the check could not be run" — it never learned the issue did not ask for that event, and changed nothing.

- **§5: every problem has one form:** `<SPEC id> <line>: <problem> | WHY: … | QUOTE: <words from that line>`, where `<line>` is `Title` (the SPEC's first line), `Given`, `When`, `Then`, `And` or `Cleanup`. A SPEC with nothing wrong is `<SPEC id>: ok`.
- **`outside` is renamed `not-asked`** and names the line whose words commit to what the issue does not ask for, or contradict it: on a part's line it marks that line; on `Title`, the first line. **`status`** is only on `Title`, with its DOC, BEFORE and WORK facts and a quote from the code. `contradicts` may also be on `Title`, and `new-owner` only there (ADR-072 §3).
- **The old forms are refused** — `<SPEC id>: outside`, `<SPEC id>: status` — and the re-ask says to write the problem on the line it is about. `status` on any line but `Title` is refused.
- **A reply's `<id> Title:` and `Steps:` lines each start a unit** of their own (`_ZB_RU_START`, `scripts/lib/reply-units.sh`), as a part's line does.

## Amendment 2026-11-18 (#2565) — §5: a refused part names what would be accepted; a requirement nothing could observe stops the run

On #1764 runs 43959139598 and 44090911022 the check refused every wording of one Then ("what a file contains", "how a test checks") and never said what it would accept. Design flipped wordings until it ran out of tries.

- An `untestable` or `how` line also says what the line could say instead: `<SPEC id> <line>: untestable | WHY: <why> | INSTEAD: <what a test could observe after the When instead> | QUOTE: <words from that line>`. A line without INSTEAD cannot be used and is asked again. Design's finding carries it. *Superseded 2026-11-20 (#2569):* INSTEAD becomes ACCEPTED IF, and every refusal carries it, not only untestable and how (see that amendment); an old INSTEAD is still read as ACCEPTED IF.
- A requirement nothing a test could observe would show met is answered `<requirement id>: none | WHY: <why> | QUOTE: <its words>`. It is not design's to fix: design stops `misconfigured`, naming the requirement and why, for the issue's owner. This replaces "say so in its WHY" for such a requirement.

## Amendment 2026-11-19 (#2567) — §5: every part of the design is judged against everything intake gave

On #1764 run 44417314654 the check was shown the issue's terms ("The engine calls its `claim` and `release` hooks through the plugin registry. The label calls live in the plugin, not in `core/`") and the steps "Create core/claim/claim.sh … wire into runner.sh", and answered `Steps: ok` on every try: it held the terms against SPEC lines only, and asked the steps one thing, whether they built a new owner. A step carried from older designs ("… trigger the shape floor") had no requirement behind it.

- **One rule for every part.** Each SPEC line, the steps and the design's decisions (its prose outside the fenced blocks, under whatever heading design gives it — `## Decision`, `## Architectural Decision Summary`, `**Decision.** …` — leaving out headings and UNCLEAR, REMOVED and WIRING lines with the lines they wrap onto) are judged against everything intake gave — the requirements, the limits, the terms and the issue's own words. Every part must be needed by them and agree with them; every requirement must be met. A part carried over from an earlier design is judged the same as a new one.
- **One answer form for a part.** `<part>: ok`, or `<part>: not-asked | contradicts | new-owner | WHY | QUOTE`. `<part>` is a SPEC line (`<id> <line>:`, as before, with its status, untestable, how and duplicate), `Steps` or `Decision`. For the steps and the decisions, not-asked and contradicts quote the part's own words; new-owner quotes a line of the code from before the change. Each problem is a finding for design naming the part.
- **The requirements and the issue's words are shown whenever the steps or the decisions are judged,** though the requirement lines are asked only when the requirements are: a part is judged against them even when only it changed.
- **A Steps or Decision quote names one part:** it lies in one step line, or one line of the decisions, and is at least three words.
- **The decisions are an item of their own,** asked only when the design has them, kept while their text, the requirements, the limits, the terms and the code from before the change are unchanged. The steps' kept answer now depends on the requirements, limits and terms too.

## Amendment 2026-11-20 (#2569) — §5 §6: every refusal says what would be accepted, in the check's own words

On #1764 run 44530053809 design's check refused a step with "make the step agree with the issue" — advice the engine added from a fixed menu, not the check's — and design read "through the plugin registry" as "call the hook functions". INSTEAD (#2565), the one text the check wrote for the case, was the one that worked.

- **§5: every problem design's check finds says what would be accepted:** `<part>: <problem> | WHY | ACCEPTED IF | QUOTE`, for a SPEC line (`<id> <line>:`, every problem word, `status` included), `Steps`, `Decision`, and a requirement's `uncovered` and `none`. **INSTEAD becomes ACCEPTED IF;** for an untestable or how line it is what a test could observe after the When. A refusal with no ACCEPTED IF cannot be used and is asked again (ADR-072 §3, amended 2026-11-20).
- **§5: ACCEPTED IF says what must be true for the part to be accepted, in the issue's words — never how to build it** (no file, function, command or change to make). The check is shown #1764's example: not `ACCEPTED IF: runner.sh calls plugin_hook_call on the claim-coordinator folder`; this: `ACCEPTED IF: the engine itself calls the claim coordinator's claim and release hooks through the plugin registry`.
- **§5: design's finding carries the check's WHY and ACCEPTED IF** — `[FIX IN DESIGN: <WHY> — ACCEPTED IF: <the check's>]` on the line it is about, `[FIX IN DESIGN: ACCEPTED IF: …]` after a step's, a decision's or an uncovered requirement's finding. The engine's fixed advice ("make the step agree with the issue", "take it out, or make it what the issue asks", "add or widen a SPEC so it covers this", "say what a test can see the code do", …) is gone. A status finding still says the status its facts give; a new-owner finding still names the existing owner.
- **§6: test-author's check too:** `missing`, `wrong`, `untestable`, `sections` and `cleanup` lines carry ACCEPTED IF, which names the SPEC line it judges the test against; its finding's mark is `[FIX IN TEST: <WHY> — ACCEPTED IF: <the check's>]` (`[FIX IN DESIGN: …]` for an untestable SPEC). "make it do what this line says", "set this up in the test", "assert this, so the test fails when it is not so", "put it back at the end of the test" and "lay the test out in … sections" are gone.
- **§5 §6: each check is held to its earlier findings** (ADR-072 §5, amended 2026-11-20): a SPEC, the requirements, the steps or the decisions it refused, which design or test-author answered, is judged again, shown the finding and the answer.
- *Review, 2026-11-20:* **§6: a test-author `missing`, `wrong` or `untestable` line with no ACCEPTED IF is judged against the SPEC line it names, whose words are its ACCEPTED IF** — the part's line (for an untestable SPEC, the part its quote is in) — and is not asked again; a `sections` or `cleanup` line, which judges the test as a whole, still is (ADR-072 §3, review). **§5 §6:** an answer has a SPEC or item judged again only while its kept verdict refuses it, and the check is told whether the part is the same as when it refused it (ADR-072 §4 §5, review).

## Amendment 2026-11-20 (#2571) — §5: design's check judges every question the design carries

On #1764 design's check left `UNCLEAR` lines out of the parts it judged (#2567, #2569), so a question the issue's Terms answered rode along through every design.

- **§5: each `UNCLEAR` line of the design is a part the check judges,** against the issue as it is now, in the same call: one more item, kept like the others while the questions, the requirements, the limits and the terms are unchanged (ADR-072 §4). The check is shown the questions and the answer forms through the block every stage's check uses (ADR-069 §12, amended 2026-11-20), and answers one line per question: `UNCLEAR <id>: answered | WHY | QUOTE: <the issue's words that answer it>`, `UNCLEAR <id>: not needed | WHY`, or `UNCLEAR <id>: open`. An answered quote is checked against the issue; a question with no line, or a line that cannot be used, is asked again, naming it.
- **§5: the questions' kept answer is judged again when the issue's own text changes** (review on #2571), not only its requirements, limits and terms: an `open` must not outlive an edit that answers it.
- **§5: a carried question the check leaves unjudged after the one re-ask stays open** (review on #2571): it does not make the check's answer unusable or fail design's try. The other items' answers stand, the run log notes it, and the next try judges it. **Design drops no question its check did not retire:** a question of the last design that passed that the new design leaves out is refused by design's form check (`UNCLEAR_DROPPED`), unless its check's finding retiring it is in the result beside that design (ADR-069 §12).
- **§5: an answered or not-needed question is a finding for design,** `UNCLEAR <id>: … [FIX IN DESIGN: ACCEPTED IF: the UNCLEAR <id> line is gone, and the work follows the issue's words where they differ from its assumption]`. Design answers it like any finding; a refusal it answers is judged again (ADR-072 §5). `open` is a pass.

## Amendment 2026-11-22 (#2584) — §5: the decisions name each outside assumption and how it is handled

On #1764 the engine claimed issues with a `zbuild:claimed` label that did not exist in the repository; the design never named the assumption. Design is told the one rule on outside assumptions (`ZB_OUTSIDE_ASSUMPTIONS_RULE`, ADR-038, amended 2026-11-22); its check now judges it.

- **§5: a judged item of the decisions.** The check is shown the rule and told that the decisions must name each outside assumption the design makes and how it is handled; one not named, or named without how it is handled, is a finding. Its form: `Decision: unhandled | WHY: <the outside thing the design assumes, and what it leaves unsaid> | ACCEPTED IF: <what the decisions must say about it> | QUOTE: <the decisions' words that rely on it>`, the quote held as a not-asked one is (three words or more, in one line of the decisions). It is a finding for design: "Decision: the design does not handle an outside assumption: <WHY> — <QUOTE> [FIX IN DESIGN: ACCEPTED IF: …]". `unhandled` is a word of the Decision line only.

## Amendment 2026-11-22 (#2586) — §5: design writes behaviour, not tests; a step's parts are numbered, one file each

On #2532 run 45017980554 the issue asked for a guard test. Design's check refused `[no-code]` because no guard existed yet, so design marked the SPEC `[code]` and added a build step "Add a guard test that scans …" over `scripts/lib/compat.sh`. Build may not touch the tests, so the step could never be done. Another step spanned three files, and build's one quote could not answer it.

- **§5: when the issue asks for a test, the requirement is the behaviour that test proves.** Design's prompt: "No step's work is writing or changing a test. When the issue asks for a test, the requirement is the behaviour that test proves: write that behaviour as the SPEC, [done] when the code already does it." Design's check's status rule: "When a SPEC is a test the issue asks for, judge the behaviour that test proves: when the code already behaves so, no test of it existing yet does not make it [code]."
- **§5: design's check flags a step whose job is writing a test,** as well as one whose areas are in the test folders (ADR-071 §1): `Steps: test | WHY: … | ACCEPTED IF: … | QUOTE: <the step's words>`, the quote held as a not-asked one is. It is a finding for design: "Steps: a step whose work is writing or changing a test — the tests are test-author's: <WHY> — <QUOTE> [FIX IN DESIGN: ACCEPTED IF: …]".
- **§5: a step, or a part of one, names one file.** A step over more than one file is split into numbered parts, `- 1.1 <what> | areas: <file> | serves: <ids>`, `- 1.2 …`. design-steps.json keeps each part's number (`step-1.1`); a step without parts keeps its place's number. Design's check refuses a step or a part whose areas list more than one file (`STEP_MANY_FILES`). Build answers each part with one quote (ADR-072 §3, amended the same day).

## Amendment 2026-11-23 (#2590) — build sees each step by its own number

Build's prompt lists the design's steps from the steps its step check uses, each as `step <its number>: <words>` with its areas: `step 1`, `step 2.1`, `step 2.2`. The plan renderer numbered steps by position, so in #2532 run 45102665787 build read parts 2.1–2.3 as steps 2, 3 and 4 and answered by those numbers, and the check found the parts unanswered. A plan with no steps still goes through the renderer (ADR-018). Test-author's check for tests nothing asks for shows the steps the same way, and an answer's `STEP:` must be one of those numbers (`2.1` included). Before, it listed them by position and read only whole numbers.

## Enforced by

- 2026-11-23 amendment (#2590: build's prompt lists steps by their own numbers) → `plugins/agent/build/tests/build-step-parts-test.sh` SP6; `tests/unit/plugin-build-prompt-render-test.sh` IB2 (amended); `tests/unit/change-traces-to-ask-test.sh` AG2

- §5 amendment 2026-11-22 (#2586: behaviour, not tests; numbered parts) → `tests/unit/design-behaviour-not-tests-test.sh` BT1 (design's prompt), BT2 (the check's status rule), BT3, BT4 (`Steps: test` and its finding), BT5 (a quote in no step is asked again); `plugins/agent/build/tests/build-step-parts-test.sh` SP1 (design-steps.json keeps the parts' numbers), SP2 (a step over two files is refused; a part with one is not), SP3 (design's prompt)

- §5 amendment 2026-11-20 (#2571 review: judged again on an issue edit; unjudged stays open; none dropped unretired) → `tests/unit/design-unclear-review-test.sh` DR1, DR2, DR4; `tests/unit/design-unclear-judged-test.sh` DU4
- §5 amendment 2026-11-20 (#2571: design's check judges the questions the design carries) → `tests/unit/design-unclear-judged-test.sh` DU1 (shown each question and the answer forms), DU2 (#1764's case: answered by the Terms, a finding for design to drop it), DU3 (open is no finding), DU4 (no line, or a quote not in the issue, is asked again), DU5 (kept like the other items); `tests/unit/unclear-one-form-test.sh` U4, U5, U8
- §5 §6 amendment 2026-11-20 (#2569: ACCEPTED IF; no engine advice; held to earlier findings) → `tests/unit/checks-accepted-if-test.sh` A2 (design: a refusal with no ACCEPTED IF is asked again — a step, a SPEC line, a first line, a requirement), A3 (design's finding carries the check's ACCEPTED IF and no fixed advice), A4 (ACCEPTED IF says what must be true, never how; #1764's example; INSTEAD gone from the prompt), A5 (test-author's check); `tests/unit/design-check-instead-test.sh` I1–I6 (in the ACCEPTED IF form); `tests/unit/checks-held-to-findings-test.sh` H1–H3 (design), H5 (test-author)
- §5 §6 review, 2026-11-20 (#2569) → `tests/unit/checks-accepted-if-test.sh` A5 (a part's line with no ACCEPTED IF is judged against that line; sections asked again); `tests/unit/checks-held-to-findings-test.sh` H8 (a pass after an answer is kept for the next try), H9 (told whether the part is the same)

- §5 amendment 2026-11-22 (#2584: the decisions are judged for outside assumptions) → `tests/unit/outside-assumptions-test.sh` OA5 (the rule and the Decision: unhandled form in the check's prompt; the line is a finding for design)
- §5 amendment 2026-11-19 (#2567: every part judged against everything intake gave) → `tests/unit/design-check-every-part-test.sh` E1 (the one rule and the forms in the prompt; terms and limits held against any part), E2 (a step against the issue is a finding naming it), E3 (a step no requirement needs is a finding naming it), E4 (a step quote not in the steps is refused), E5 (the decisions are judged), E6 (a missing Decision line is asked again), E7 (the old new-owner form reads), E8 (no decisions, no Decision line), E9 (a decisions-only change asks only the Decision line); `tests/unit/issue-terms-test.sh` TM5; E9 (the requirements and the issue's words are shown when only the decisions are asked), E10 (the decisions are the design's prose under any heading; prose after a block in the section is kept; UNCLEAR, REMOVED, WIRING and headings are not), E11 (a quote is at least three words and lies in one step or one line of the decisions)
- §5 amendment 2026-11-18 (#2565: INSTEAD; none) → `tests/unit/design-check-instead-test.sh` I1 (both forms in the prompt), I2 (INSTEAD reaches design), I3 (an untestable or how line without INSTEAD is asked again), I4 (none is read), I6 (a bold INSTEAD is read), I5 (none stops design misconfigured, naming the requirement and why)

- §5 amendment 2026-11-16 (#2555: one form for every problem) → `tests/unit/design-one-form-test.sh` F1 (the form in the prompt; no outside), F2 (not-asked on a part's line marks it, with its WHY), F3 (on Title, the first line), F4 (status on Title), F5 (the old forms refused, the re-ask names the line), F6 (status off Title refused), F9 (a reply's `<id> Title:` and `Steps:` lines each start a unit); `tests/unit/design-status-check-test.sh` S1–S11 and `tests/unit/design-coverage-test.sh` X1, X2, X4, X5 (in the new form)

- §1 §5 §6 amendment 2026-11-14 (#2543: Given is the situation; Cleanup is the test's; how covers test steps) → `tests/unit/gwt-situation-not-setup-test.sh` G1–G7; `tests/unit/gwt-format-test.sh` D1, P2; `tests/unit/gwt-judges-test.sh` J6, J7

- §1 §2 §5 §6 amendment 2026-11-04 (#2470) → `tests/unit/judge-feedback-test.sh` F1 (the one-line SPECs named), F2 (parts as written; a part named by word and quote), F3 (findings shown once), F5 (the SPEC whole, marked), F6 (a line per SPEC); `tests/unit/reply-multiline-test.sh` Q4 (an `And` line is its own item)

- §1 §2 → `tests/unit/gwt-format-test.sh` P1–P5, R1, R2
- §3 → `tests/unit/gwt-format-test.sh` C1–C5
- §1 (design's prompt) → `tests/unit/gwt-format-test.sh` D1
- §4 → `tests/unit/gwt-judges-test.sh` T10
- §5 → `tests/unit/gwt-judges-test.sh` J1–J8
- §6 → `tests/unit/gwt-judges-test.sh` T1–T9
- §7 → `tests/unit/gwt-format-test.sh` B1
- Amendment 2026-11-05 §6 (#2474) → `tests/unit/acceptance-testfile-sections-test.sh` S1–S3 (headings shown, other comments not); `tests/unit/gwt-judges-test.sh` T1 (the question), T4b, T4c (a sections quote is checked), T8 (untestable ends the round)
