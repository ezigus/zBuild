# ADR-071 — Each output names its topic; each stage takes only the topics it needs

**Status:** Accepted (2026-10-27)
**Issue:** #1944 (run 40393999128)
**Amends:** ADR-067 §8 (Previous work), ADR-068 §6 and §8 (every stage's latest output goes to every later stage)
**Related:** ADR-055 (inter-stage data contract), ADR-060 (stages return structure), ADR-066 (every ADR statement has a test)

## Context

Every stage was handed the latest output of every stage that had run (ADR-068 §8), and told to answer every finding it received (ADR-068 §6). On #1944 run 40393999128, design's second round was handed the test stage's failing files, the path of every test log, and issue-acceptance's findings, most of them bugs in the code. Its prompt said to leave those alone. To decide which findings were its own, it investigated every one: it read `test-output.log`, ran `git diff` on `runner.sh` and grepped the tests, and both 20-minute calls ran out of time with the design unchanged. Its earlier design had already turned into a bug list with `file:line` fixes, because the same material had reached it the round before.

The prompt was not enough. A stage should not be handed what its job does not use.

## Decision

1. **Every output names its topic.** In the stage's manifest, each output has `topic:`, one of five:
   - `ask` — what is to be built: the issue, the requirements, the plan, the design;
   - `tests` — the tests written for the change, and what each covers;
   - `change` — the code the change made, and its summary;
   - `requirement-findings` — what checks found against the requirements and the design: issue-acceptance, design's own checks, the acceptance check on each requirement's test;
   - `code-findings` — what checks found in the code and the tests: the test suite, the test checker, the review lenses.
   A finding takes the topic of the output it is in. The words are checked at load: a manifest naming any other topic is refused, naming the word.
2. **Every stage that calls a model names the topics it takes:** `takes: [ask, change]`. Previous work holds only the outputs of those topics — their paths, summaries, findings and errors. The line naming the files the work has changed is a `change`. A stage's own notes always come back to it. An output with no topic reaches no stage that declares `takes:`; a stage with no `takes:` is shown everything, as before.
3. **What each shipped stage takes:**

   | Stage | Takes |
   |---|---|
   | plan | ask |
   | design | ask, requirement-findings |
   | test-author | ask, tests, code-findings — never `change`: it does not see the code it is testing |
   | build | ask, tests, change, requirement-findings, code-findings |
   | issue-acceptance | ask, change, code-findings |
   | review lenses, monitor | ask, change |

4. **`takes:` is what a stage looks for, not what it needs.** A topic with nothing in it is left out of the prompt. A stage that cannot work without something checks for it itself and says so (test-author refuses to run without the design's requirements).
5. **A stage answers only the findings it is given** (amends ADR-068 §6). Since it is given only the topics it takes, the findings it answers are those.

## Consequences

- Design no longer sees the test suite's output or the code; it sees whether each requirement was met, and its own checks. A design problem that build hits but that never shows as an unmet requirement does not reach design; build goes round until its rounds run out, as before (ADR-068 §8).
- The engine still keeps nothing but stage outputs and judges nothing a stage wrote: it filters by a word the producing stage's manifest declares.
- A new stage declares its outputs' topics and what it takes; a new topic is a change to this ADR.

## Implementation Notes

- `core/plugin-registry/manifest-validation.sh`: `ZBUILD_STAGE_TOPICS`; `validate_manifest` refuses an unknown `topic:` or `takes:` word.
- `scripts/lib/stage-previous-work.sh`: `_sp_manifest_roles_v` reads each output's topic; `_sp_takes_v` reads the stage's `takes:`; `_stage_block_previous_work` (given the stage's manifest by `stage_blocks_write_v`) shows only what the stage takes.

## Enforced by

- §1 → `tests/unit/stage-takes-topics-test.sh` T6 (an unknown topic or take is refused, naming it), T7 (every output of the shipped stages names its topic)
- §2 → `tests/unit/stage-takes-topics-test.sh` T1 (only the topics taken: paths, summaries, findings, errors), T2 (no topic → no stage with `takes:`), T3 (no `takes:` → everything), T4 (the changed-files line is a `change`), T5 (own notes), T8 (the dispatch passes the stage's own manifest)
- §3 → `tests/unit/stage-takes-topics-test.sh` T7 (each shipped stage's `takes:`; every stage that composes a model prompt declares one)
- §4 → `tests/unit/stage-takes-topics-test.sh` T1 (a stage that takes a topic with nothing in it is not shown the stage that wrote only other topics)
- §5 → `tests/unit/stage-takes-topics-test.sh` T1 (the findings of a topic not taken are not in the prompt)
