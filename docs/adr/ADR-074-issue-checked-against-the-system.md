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
2. **Four judgements, one per requirement**, in the block form (ADR-072 §3): `NEEDED`; `DONE` (the system already does it); `CONTRADICTS` (a live ADR decided otherwise — a requirement that would reverse a recorded decision is this: only the issue's author may reverse it); `GONE` (it is about code, a check, an event or a file that has been removed or replaced). Every judgement but `NEEDED` quotes `<file> | <line>`, checked against the repository; a quote that is not there is asked again once, then the answer is `unusable` — the run never stops on a guess.
3. **Any requirement not `NEEDED` ends the run**, `misconfigured` (the operator fixes it — ADR-054 §6). Its reason says the issue needs rewriting and names each requirement and its judgement; each is a finding in its result (for the reports only: no stage takes it), with why, the quote, and what the issue could ask instead (`ACCEPTED IF`). The answer ends with a better set of requirements (`SUGGEST:` lines), kept in the result (`data.suggested`) and shown in its report; a problem with none is asked again.
4. **It runs on every run**, a rerun included, and keeps no earlier verdict: the code moves between runs even when the issue does not.
5. **One read-only call** (`calls: main: [read-files, read-git, read-github]`), as the architect.
6. **The process budget rises once** for the stage's dispatch (ADR-065); the cost of what was there before does not.

## Enforced by

- §1 → `tests/unit/template-simple-yaml-test.sh` SPEC-2, SPEC-11 (issue-check after intake, before the loop), and `[#2614] deployed.yaml runs no issue-check`
- §2 → `plugins/agent/issue-check/tests/issue-check-test.sh` IC1 (the prompt and its forms), IC3 (DONE), IC4 (CONTRADICTS, quoting an ADR), IC5 (GONE), IC6 (a quote that is not there: asked again, then unusable), IC7 (a requirement with no line)
- §3 → `plugins/agent/issue-check/tests/issue-check-test.sh` IC2 (all needed: pass), IC3 (misconfigured; the reason; the finding's why, quote and ACCEPTED IF; the report and data.suggested; no stage takes it), IC8 (no better set: asked again), IC11 (no requirements: pass)
- §4 → `plugins/agent/issue-check/tests/issue-check-test.sh` IC9
- §5 → `plugins/agent/issue-check/tests/issue-check-test.sh` IC10
- §6 → `tests/e2e/fork-budget-test.sh` (the budgets, raised for the one dispatch)
