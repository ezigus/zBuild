# ADR-073 — A requirement and its test are written as Given/When/Then, and every part is judged

**Status:** Accepted (2026-11-04); amended 2026-11-04 (#2470, §1 §2 §5 §6: a SPEC is shown with its parts as design wrote them; design is told which SPECs it keeps are still on one line; a finding shows the failing SPEC whole, marked where to fix it; the checks answer per SPEC); amended 2026-11-05 (#2474, §6: an untestable SPEC ends the round; the check sees the section headings)
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
- **test-author:** `plugins/agent/test-author/lib/correspondence.sh` (`_sc_judge`, `_sc_batch_prompt`, `_ta_correspondence`); `plugins/agent/test-author/plugin.sh` (the parts in its prompt, the sections, and a `misconfigured` result for a SPEC no test can prove).
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

## Enforced by

- §1 §2 §5 §6 amendment 2026-11-04 (#2470) → `tests/unit/judge-feedback-test.sh` F1 (the one-line SPECs named), F2 (parts as written; a part named by word and quote), F3 (findings shown once), F5 (the SPEC whole, marked), F6 (a line per SPEC); `tests/unit/reply-multiline-test.sh` Q4 (an `And` line is its own item)

- §1 §2 → `tests/unit/gwt-format-test.sh` P1–P5, R1, R2
- §3 → `tests/unit/gwt-format-test.sh` C1–C5
- §1 (design's prompt) → `tests/unit/gwt-format-test.sh` D1
- §4 → `tests/unit/gwt-judges-test.sh` T10
- §5 → `tests/unit/gwt-judges-test.sh` J1–J8
- §6 → `tests/unit/gwt-judges-test.sh` T1–T9
- §7 → `tests/unit/gwt-format-test.sh` B1
- Amendment 2026-11-05 §6 (#2474) → `tests/unit/acceptance-testfile-sections-test.sh` S1–S3 (headings shown, other comments not); `tests/unit/gwt-judges-test.sh` T1 (the question), T4b, T4c (a sections quote is checked), T8 (untestable ends the round)
