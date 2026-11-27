# ADR-075 — Every output traces to the work it was handed

**Status:** Accepted (2026-11-26)
**Issue:** #2629 (#1722 run 45872552515)
**Amends:** ADR-072 §3 (a file a test needs is not asked for by that test's requirement), ADR-070 §1 §3 (NOT-A-REQUIREMENT for an item the issue does not state; design's mapping both ways), ADR-068 §6 (the #2575 sentence "build's every change traces to a step or a failing test": a failing test is a finding, and the trace is now read by script)
**Related:** ADR-069 (design's acceptance contract, `covers:`), ADR-070 §1 (intake's list), ADR-072 §3 (judging calls), ADR-040 (the lenses), ADR-066 (every ADR statement has a test)

## Context

On #1722 run 45872552515 build changed `scripts/lib/acceptance-block.sh` — a shared parser no design step named — so that a test of a "malformed block" would pass; the test had used an example today's code does not call malformed. Nine of design's tests broke. issue-acceptance then said "no requirement asks for it", and accepted it if the file stayed under 500 lines; the scope lens judged the change "needed for the test". Three stages had a version of the same rule — design (every requirement has a SPEC), test-author (an assertion no SPEC or step asks for is taken out), issue-acceptance (a part no requirement asks for) — each in its own words, and build had none. Both judges also let "a test needs it" stand for "something asks for it".

## Decision

1. **One rule for every stage that produces work from what it was handed, or judges whether work was asked for — intake's check, design, test-author, build, issue-acceptance and the scope lens: everything it produces traces to the work it was handed.** (The other model calls — issue-check, the other lenses, the judging calls of ADR-072 — judge what they are shown and produce nothing a later stage builds on; they are not given it.) A piece that traces to nothing is taken out, or the stage answers not mine and names the stage that must add what asks for it. It is never kept on a condition about how it is done (its size, its place, its form). The rule and its finding are written once (`scripts/lib/trace.sh`: `zb_trace_rule_v`, `zb_trace_list_rule_v`, `zb_trace_finding_v`) and every stage uses them. **A test is asked for by what it tests, and a helper or fixture it reads is part of it; a change to the code that only a test needs is asked for by nothing, and neither is the test.**
2. **By name, read by script** (`zb_trace_covered`):
   - **build:** every file its round changed, outside the test folders, lies in a design step's areas or is named by a done answer to a finding build was given. The round's files are the working tree against the round's base, before its first pass (`round.sh`), so every pass's commits are in it — one git call, NUL-separated, so a name with a space is read whole; a moved file is its new path, a removed one its path (`_build_trace_files_v`). A done answer counts only for a finding build's prompt showed it (or its own latest result holds), only by the file in its slot — `ANSWER <its id>: done — <file> | <a line you added> — <what you changed>` — matched exactly, and never as an answer to build's own untraced finding (`_build_trace_check`, `plugins/agent/build/lib/steps-trace.sh`). An area is read less its marks (backticks, quotes, a leading `./`); `.` is the whole repository; an area is never a pattern, and design's prompt says so. Any other file is a finding, and the try is `unusable` (reason `untraced_change`). With no steps there is nothing to trace to.
   - **A failing test is a finding build was given.** A fix a test failure needs, in a file no step names, is traced by build's done answer to that finding naming the file — it costs no round. Only a change nothing asks for costs one.
   - **The way out is design's.** Build answers its own untraced finding `not mine — design must add a step whose areas hold <file>`: the finding goes to design (`build-design-result.json`, topic design-findings), it waits there blocking nothing of build's, and the try fails so the round ends and design runs (`_build_write_handoffs`, `_BUILD_STEP_WAITING`).
   - **Not ADR-036's named file.** The acceptance check's `WIRING:` line names the one file that calls new code, and puts every other changed file back to see whether the tests still pass; it says nothing of a file changed that nothing asks for. This check reads every file the round changed against what build was handed, and runs no test.
   - **design:** every SPEC names in its `covers:` an id intake listed; one that covers nothing (`SPEC_COVERS_NOTHING`) or an id intake did not list (`SPEC_COVERS_UNKNOWN`, read as written, never a pattern) is refused (`_dck_specs_trace`, `plugins/agent/design/lib/checks-trace.sh`). A SPEC covering a limit is not untraced: it is refused as before, for building what the limit forbids (`LIMIT_COVERED`, ADR-069). With no list, nothing is asked.
3. **By meaning, judged by a model**, each check given the rule:
   - **intake's check** names a listed item the issue does not state, in a `NOT-A-REQUIREMENT:` line, and it leaves the list;
   - **test-author's unasked check** is given the rule, and its finding is the shared one;
   - **issue-acceptance's reverse question** is given the rule — a file a test needs is no longer asked for by that test's requirement — and its `accepted if` for a part no requirement asks for is only "the change without it, or the requirement that would ask for it — nothing else". The reader holds it to that: whatever the reply's `accepted if` says, an UNASKED finding's ACCEPTED IF is "the change without it, or a requirement that asks for it" (`_ia_parse_unasked`, `plugins/agent/issue-acceptance/lib/parse.sh`);
   - **the scope lens** judges by the rule: its job names it by a mark (`@TRACE_RULE@`, filled by `_rl_lens_job_v` from `zb_trace_rule_v`), and "a file that test needs" is no longer an exemption.

## Consequences

- A stage that changes or writes more than it was handed is told so the same way everywhere, and the fix is the same: take it out, or the stage that hands the work adds it.
- Build's done answers to findings name files, so a file changed to fix a failing test traces to that finding.
- A design whose SPECs name no requirement intake listed no longer passes when a requirements list exists.

## Implementation Notes

- `scripts/lib/trace.sh` holds the rule, its list form, its finding and `zb_trace_covered`; no stage writes its own words for it.
- build: `_build_trace_check` (`plugins/agent/build/lib/steps-trace.sh`) runs in `_build_write_build_summary` after the step check, over `files_changed_json` read by the shell (`_build_json_strings_v`) and the answers `_build_answers_json_v` reads once — no process added.
- design: `_dck_specs_trace` (`plugins/agent/design/lib/checks-trace.sh`) runs in C7 of `_design_checks`, its words from `_dck_trace_plain`.
- The judged checks take the rule from `zb_trace_rule_v` / `zb_trace_list_rule_v`; the scope lens's job names it by `@TRACE_RULE@`, which `_rl_lens_job_v` fills.

## Enforced by

- §1 → `tests/unit/trace-rule-test.sh` T1 (a path in an area; the rule's words: what was handed, a change only a test needs, taken out or added, never kept on a condition; the finding)
- §2 build → `tests/unit/trace-rule-test.sh` T2 (a file in no step's areas is a finding; a done answer's slot to a shown finding traces it; not one never shown, not the file in its words, not another file's slot, not a longer path, not its own untraced finding, not a wrong; not mine to design waits; a test file, no steps: none; areas with ./ and backticks), T2b (the round's files: an earlier pass's commit, a move's new path, a removal, a name with a space), T3 (build's prompt); `plugins/agent/build/tests/build-step-answers-test.sh` BS23 (the try is unusable, untraced_change), BS24 (a second pass: the first pass's commit is still traced), BS25 (not mine reaches design; the round ends); `tests/unit/design-behaviour-not-tests-test.sh` BT1 (design's prompt: an area is a path); `tests/unit/change-traces-to-ask-test.sh` A1
- §2 design → `tests/unit/trace-rule-test.sh` T4 (requirements from intake's writer; covers nothing, an unknown id, an id without intake's prefix, a pattern: refused; listed: not; a limit: LIMIT_COVERED, not untraced; no list: nothing asked)
- §3 → `tests/unit/trace-rule-test.sh` T5 (intake), T6 (test-author), T7 (issue-acceptance: the rule; no sentence says what a test needs is asked for), T8 (the scope lens: its own sentence in the built prompt; nothing under Not a finding exempts what a test needs), T9 (issue-acceptance's reader: a size condition becomes "without it, or a requirement"); `tests/unit/change-traces-to-ask-test.sh` A3 (test-author's finding); `tests/unit/issue-acceptance-unasked-test.sh` U1
