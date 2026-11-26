# ADR-074 — An issue is checked against the system as it is before work starts

**Status:** Accepted (2026-11-26)
**Issue:** #2614 (#1722 run 45739271221)
**Amends:** ADR-070 §1 (intake reads only the issue; this stage reads the system)
**Related:** ADR-054 §6 (`misconfigured` ends the run), ADR-068 §3 (`requires:`), ADR-051 §2 (personas), ADR-072 §3 (the block answer form, quotes checked), ADR-066 (every ADR statement has a test)

## Context

#1722 was written in August against the shape-floor check. #2556 removed that check and its `shape_floor.*` events on Nov 16, and ADR-040 says they stay removed. On #1722 run 45739271221:

- intake restated the requirements as written — it answers from the issue alone, with no tools and one turn (#2448), by design;
- design saw "the shape-floor result" as an unclear word, assumed a reading, and wrote an ADR-040 amendment that "supersedes" #2556;
- no lens used `fix: issue`, the word for an issue that contradicts an ADR.

The run spent 2h11m and $20 re-adding what an ADR had removed, and opened no PR. Nothing in the pipeline compared the issue with the system as it is.

## Decision

1. **A stage of its own, after intake, before the design loop** (`issue-check`, `plugins/agent/issue-check`). Intake stays an issue reader with no tools; judging the issue against the code needs tools, a stronger model and a judgement intake would be making about its own restatement. It is in `simple.yaml` only: `deployed.yaml` runs the last steps of a change already built.
2. **Four judgements, one per requirement**, in the block form (ADR-072 §3), a numbered, bulleted or headed first line read as one: `NEEDED`; `DONE` (the system already does it); `CONTRADICTS` (a live ADR decided otherwise and the issue does not say it changes that decision — a requirement that would reverse a recorded decision is this, since only the issue's author may reverse it; an issue that names the ADR and says it amends or supersedes the statement is `NEEDED`); `GONE` (it is about code, a check, an event or a file that has been removed or replaced). Every judgement but `NEEDED` quotes `<file> | <a line of at least three words>`, checked against the repository; a `CONTRADICTS` quote is an ADR's line, in `docs/adr/`. A requirement with no line, two lines, or a quote that is missing, too short or not in its file is asked again once, then the answer is `unusable` — the run never stops on a guess.
   **The system is where the run's branch began.** On a rerun the branch holds this issue's own earlier work; the call is told the commit the branch started from on the default branch (its merge-base), and judges the system as it is there, so its own earlier work is never read as `DONE`.
3. **Any requirement not `NEEDED` ends the run**, `misconfigured` (the operator fixes it — ADR-054 §6), and the stage exits non-zero, so the runner names it with its reason (`stopped: issue-check stopped the run — the issue needs rewriting: …`). The reason names each requirement and its judgement; each is a finding in its result (for the reports only: no stage takes it), with why, the quote, and what the issue could ask instead (`ACCEPTED IF`). The answer ends with a better set of requirements (`SUGGEST:` lines): kept in the result (`data.suggested`), shown in its report, and one more finding, so the run's last comment lists it among the open items. A problem with no better set is asked again. An issue run whose requirements intake did not write is `broken`; a goal run, with no issue, passes.
4. **It runs on every run**, a rerun included, and keeps no earlier verdict: the code moves between runs even when the issue does not. A `--resume` continues the same run, and skips a stage that completed in it, as for every stage.
5. **One read-only call** (`calls: main: [read-files, read-git, read-github]`), as the architect.
6. **The process cost:** a simple run makes one more dispatch, the per-dispatch cost ADR-065 §6 budgets. The cost of what was there before does not rise: the budgets of the mocked full run (whose own template has no issue-check) are unchanged.

## Implementation Notes

- `plugins/agent/issue-check/plugin.sh`: the prompt (`_ic_prompt`), the reader (`_ic_plain_v`, `_ic_parse`, over `zb_reply_join_v` and `judge_reply_line_v`), quotes checked by `judge_quote_check_v`, findings numbered by `stage_findings_route_each` with the `report` topic (no stage takes them), the starting commit from `zbuild_resolve_merge_base_v`.
- `config/templates/simple.yaml`: `issue-check` after `intake`; `retry: 1` for an unusable answer.
- `core/pipeline/template.sh`: `requires: all` leaves out a `blocking: false` stage (ADR-068 §3, amended).

## Enforced by

- §1 → `tests/unit/template-simple-yaml-test.sh` SPEC-2, SPEC-11 (issue-check after intake, before the loop), and `[#2614] deployed.yaml runs no issue-check`
- §2 → `plugins/agent/issue-check/tests/issue-check-test.sh` IC1 (the prompt and its forms), IC3 (DONE), IC4 (CONTRADICTS, quoting an ADR), IC5 (GONE), IC6 (a quote that is not there: asked again, then unusable), IC7 (a requirement with no line), IC13 (every judgement's quote: none, another file, too short, a CONTRADICTS not from an ADR), IC14 (a numbered or bulleted answer), IC16 (the starting commit), IC17 (an issue that amends the ADR)
- §3 → `plugins/agent/issue-check/tests/issue-check-test.sh` IC2 (all needed: pass), IC3 (misconfigured, rc 1; the reason; the finding's why, quote and ACCEPTED IF; the report and data.suggested; no stage takes it), IC8 (no better set: asked again), IC11 (a goal run passes; no requirements on an issue run: broken), IC12 (two problems), IC18 (the open items show the problems, their quotes and the better set); `tests/integration/issue-check-stops-run-test.sh` SR1 (the runner stops before design, naming issue-check and its reason)
- §4 → `plugins/agent/issue-check/tests/issue-check-test.sh` IC9
- §5 → `plugins/agent/issue-check/tests/issue-check-test.sh` IC10 (the call's tools and persona), IC15 (no file of the repository changes)
- §6 → `tests/e2e/fork-budget-test.sh` (the per-dispatch and full-run budgets, unchanged)
