# ADR-075 — Every output traces to the work it was handed

**Status:** Accepted (2026-11-26)
**Issue:** #2629 (#1722 run 45872552515)
**Amends:** ADR-068 §6 (the #2575 sentence "build's every change traces to a step or a failing test": a failing test is a finding, and the trace is now read by script)
**Related:** ADR-069 (design's acceptance contract, `covers:`), ADR-070 §1 (intake's list), ADR-072 §3 (judging calls), ADR-040 (the lenses), ADR-066 (every ADR statement has a test)

## Context

On #1722 run 45872552515 build changed `scripts/lib/acceptance-block.sh` — a shared parser no design step named — so that a test of a "malformed block" would pass; the test had used an example today's code does not call malformed. Nine of design's tests broke. issue-acceptance then said "no requirement asks for it", and accepted it if the file stayed under 500 lines; the scope lens judged the change "needed for the test". Three stages had a version of the same rule — design (every requirement has a SPEC), test-author (an assertion no SPEC or step asks for is taken out), issue-acceptance (a part no requirement asks for) — each in its own words, and build had none. Both judges also let "a test needs it" stand for "something asks for it".

## Decision

1. **One rule for every stage that makes a model call: everything it produces traces to the work it was handed.** A piece that traces to nothing is taken out, or the stage answers not mine and names the stage that must add what asks for it. It is never kept on a condition about how it is done (its size, its place, its form). The rule and its finding are written once (`scripts/lib/trace.sh`: `zb_trace_rule_v`, `zb_trace_list_rule_v`, `zb_trace_finding_v`) and every stage uses them. **A test is asked for by what it tests, and a helper or fixture it reads is part of it; a change to the code that only a test needs is asked for by nothing, and neither is the test.**
2. **By name, read by script** (`zb_trace_covered`):
   - **build:** every file its round changed (every try's, `round.sh`), outside the test folders, lies in a design step's areas or is named by a done answer to a finding build was given (its answers, those an earlier try's result carries included). Any other file is a finding, and the try is `unusable` (reason `untraced_change`) (`_build_trace_check`, `plugins/agent/build/lib/steps-trace.sh`). Build's prompt says a done answer to a finding names each file it changed: `ANSWER <its id>: done — <file> | <a line you added> — <what you changed>`. With no steps there is nothing to trace to.
   - **design:** every SPEC names in its `covers:` a requirement or limit intake listed; one that covers nothing (`SPEC_COVERS_NOTHING`) or an id intake did not list (`SPEC_COVERS_UNKNOWN`) is refused (`_dck_specs_trace`, `plugins/agent/design/lib/checks-trace.sh`). With no list, nothing is asked.
3. **By meaning, judged by a model**, each check given the rule:
   - **intake's check** names a listed item the issue does not state, in a `NOT-A-REQUIREMENT:` line, and it leaves the list;
   - **test-author's unasked check** is given the rule, and its finding is the shared one;
   - **issue-acceptance's reverse question** is given the rule — a file a test needs is no longer asked for by that test's requirement — and its `accepted if` for a part no requirement asks for is only "the change without it, or the requirement that would ask for it — nothing else";
   - **the scope lens** judges by the rule: its job names it by a mark (`@TRACE_RULE@`, filled by `_rl_lens_job_v` from `zb_trace_rule_v`), and "a file that test needs" is no longer an exemption.

## Consequences

- A stage that changes or writes more than it was handed is told so the same way everywhere, and the fix is the same: take it out, or the stage that hands the work adds it.
- Build's done answers to findings name files, so a file changed to fix a failing test traces to that finding.
- A design whose SPECs name no requirement intake listed no longer passes when a requirements list exists.

## Enforced by

- §1 → `tests/unit/trace-rule-test.sh` T1 (a path in an area; the rule's words: what was handed, a change only a test needs, taken out or added, never kept on a condition; the finding)
- §2 build → `tests/unit/trace-rule-test.sh` T2 (a file in no step's areas and named by no done answer is a finding; a step's file, a named file, a test file, no steps: none; a wrong answer does not count), T3 (build's prompt); `plugins/agent/build/tests/build-step-answers-test.sh` BS23 (the try is unusable, untraced_change); `tests/unit/change-traces-to-ask-test.sh` A1
- §2 design → `tests/unit/trace-rule-test.sh` T4 (covers nothing, an unknown id: refused; listed: not; no list: nothing asked)
- §3 → `tests/unit/trace-rule-test.sh` T5 (intake), T6 (test-author), T7 (issue-acceptance), T8 (the scope lens); `tests/unit/change-traces-to-ask-test.sh` A3 (test-author's finding)
