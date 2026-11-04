# ADR-073 — A requirement and its test are written as Given/When/Then, and every part is judged

**Status:** Accepted (2026-11-04)
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

   The parts are labelled for the checks: `Given 1`, `When`, `Then 2`, `Cleanup 1`.

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
   - A SPEC no test can prove (`<id>: untestable`) ends the run at once: test-author's result is `misconfigured`, naming the SPEC and why, as design's to rewrite. Nothing loops back.

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
- **The part line in a reply:** `scripts/lib/reply-units.sh` treats a line like `FRSH-1 Then 2:` as the start of an item.
- **design:** `plugins/agent/design/lib/checks.sh` (C10: `_dck_parts`, `_dck_plain`) and `plugins/agent/design/lib/coverage.sh` (`_dcov_part_line`, `_design_coverage_findings`); the prompt in `plugins/agent/design/plugin.sh`.
- **test-author:** `plugins/agent/test-author/lib/correspondence.sh` (`_sc_judge`, `_sc_batch_prompt`, `_ta_correspondence`); `plugins/agent/test-author/plugin.sh` (the parts in its prompt, the sections, and a `misconfigured` result for a SPEC no test can prove).
- **Other readers:** build (`plugins/agent/build/lib/context.sh`, `plugins/agent/build/lib/prompt.sh`), issue-acceptance (`acceptance_requirements_for_judge`), and the review lenses (`_rl_requirements_readable`).

## Enforced by

- §1 §2 → `tests/unit/gwt-format-test.sh` P1–P5, R1, R2
- §3 → `tests/unit/gwt-format-test.sh` C1–C5
- §1 (design's prompt) → `tests/unit/gwt-format-test.sh` D1
- §4 → `tests/unit/gwt-judges-test.sh` T10
- §5 → `tests/unit/gwt-judges-test.sh` J1–J8
- §6 → `tests/unit/gwt-judges-test.sh` T1–T9
- §7 → `tests/unit/gwt-format-test.sh` B1
