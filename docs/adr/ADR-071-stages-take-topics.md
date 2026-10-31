# ADR-071 — Each output names its topic; each stage takes only the topics it needs

**Status:** Accepted (2026-10-27); amended 2026-10-28 (§3: test-author takes requirement-findings); amended 2026-10-30 (#2428, §1 §2: each stage states its contract; every finding a stage takes reaches it); amended 2026-10-31 (#2441, §1: build writes its answers that a test is wrong to its own code-findings output)
**Issue:** #1944 (run 40393999128)
**Amends:** ADR-067 §8 (Previous work), ADR-068 §6 and §8 (every stage's latest output goes to every later stage)
**Related:** ADR-055 (inter-stage data contract), ADR-060 (stages return structure), ADR-066 (every ADR statement has a test)

## Context

Every stage was handed the latest output of every stage that had run (ADR-068 §8), and told to answer every finding it received (ADR-068 §6). On #1944 run 40393999128, design's second round was handed the test stage's failing files, the path of every test log, and issue-acceptance's findings, most of them bugs in the code. Its prompt said to leave those alone. To decide which findings were its own, it investigated every one: it read `test-output.log`, ran `git diff` on `runner.sh` and grepped the tests, and both 20-minute calls ran out of time with the design unchanged. Its earlier design had already turned into a bug list with `file:line` fixes, because the same material had reached it the round before.

The prompt was not enough. A stage should not be handed what its job does not use.

## Decision

1. **Every output a later stage may need names its topic.** In the stage's manifest, the output has `topic:`, one of five (an output no stage takes — monitor's report, deploy's and the pull request's results, hydrate's and persist's — names none, and reaches no stage that declares `takes:`, §2):
   - `ask` — what is to be built: the issue, the requirements, the plan, the design;
   - `tests` — the tests written for the change, and what each covers;
   - `change` — the code the change made, and its summary;
   - `requirement-findings` — what checks found against the requirements and the design: issue-acceptance, design's own checks, the acceptance check on each requirement's test;
   - `code-findings` — what checks found in the code and the tests: the test suite, the test checker, the review lenses.
   A finding takes the topic of the output it is in, and lives in one output: a stage does not copy one output's findings into another. The words are checked at load: a manifest naming any other topic is refused, naming the word.

   *Amended 2026-10-30 (#2428):* every output that names a topic also has a one-line `description:` saying what it holds, including the kinds of findings it can carry. The description sits on the output entry in the producing stage's manifest; two stages may produce the same type, and each describes its own output. A template author reads these, with each take's `for:` (§2), to see whether a finding reaches a stage that can act on it; the engine does not judge them. `validate_manifest` refuses an output with a topic and no description.
   *Amended 2026-10-30 (#2433):* a review lens declares one output per topic it writes findings to: `lens-<id>-code-result.json` (`code-findings`: what the code or a test must fix) and `lens-<id>-design-result.json` (`requirement-findings`: what the design must fix, or that the issue itself is wrong). A lens names what would fix a finding, never a stage; the topic carries it to the stages that take it.
2. **Every stage that calls a model names the topics it takes,** each with what it looks for there:
   ```yaml
   takes:
     - topic: ask
       for: the issue, its requirements and the plan, to design against
   ```
   The engine reads only `topic`; `for:` is the stage's contract for whoever writes the template. `validate_manifest` refuses a take with no `for:` and the old one-line form. Previous work holds only the outputs of those topics — their paths, summaries, findings and errors. *Amended 2026-10-30 (#2428):* the findings of **every** output of a taken topic are shown, not only the stage's primary output's. Findings in the primary output are labelled `<stage> finding <n>`; findings in another output by that output's file name without `-result.json` (the name `open_items_json` gives them), e.g. `acceptance-gate finding 1 (opened by test)`. In #1951's run the acceptance check's finding sat in test's `acceptance-gate-result.json` (`requirement-findings`) and was never read, because only test's primary output (`code-findings`) was; design never saw it. The line naming the files the work has changed is a `change`. A stage's own notes always come back to it. An output with no topic reaches no stage that declares `takes:`; a stage with no `takes:` is shown everything, as before.
3. **What each shipped stage takes:**

   | Stage | Takes |
   |---|---|
   | plan | ask |
   | design | ask, requirement-findings |
   | test-author | ask, tests, requirement-findings, code-findings — never `change`: it does not see the code it is testing |
   | build | ask, tests, change, requirement-findings, code-findings |
   | issue-acceptance | ask, change, code-findings |
   | review lenses, monitor | ask, change |

   *Amended 2026-10-28:* test-author takes `requirement-findings`. Without it, a finding that a test misses a requirement (#1944: "R-4's test builds no `persist` stage") reached build, which may not edit the acceptance tests, and design, which does not run inside the build-and-test loop — so no stage in that loop could answer it, and every round repeated it.

4. **`takes:` is what a stage looks for, not what it needs.** A topic with nothing in it is left out of the prompt. A stage that cannot work without something checks for it itself and says so (test-author refuses to run without the design's requirements).
5. **A stage answers only the findings it is given** (amends ADR-068 §6). Since it is given only the topics it takes, the findings it answers are those.

## Consequences

- Design no longer sees the test suite's output or the code; it sees whether each requirement was met, and its own checks. A design problem that build hits but that never shows as an unmet requirement does not reach design; build goes round until its rounds run out, as before (ADR-068 §8).
- The engine still keeps nothing but stage outputs and judges nothing a stage wrote: it filters by a word the producing stage's manifest declares.
- A new stage declares its outputs' topics and what it takes; a new topic is a change to this ADR.

## Implementation Notes

- `core/plugin-registry/manifest-validation.sh`: `ZBUILD_STAGE_TOPICS`; `validate_manifest` refuses an unknown `topic:` or `takes:` word, a take with no `for:`, the one-line `takes:` form, and an output with a topic and no `description:`.
- `plugins/tool/test/lib/own-checks.sh`: the shape check's and the acceptance check's findings stay in their own results; test's result names a failed check in its reason.
- `scripts/lib/stage-previous-work.sh`: `_sp_manifest_roles_v` reads each output's topic; `_sp_takes_v` reads the stage's `takes:`; `_stage_block_previous_work` (given the stage's manifest by `stage_blocks_write_v`) shows only what the stage takes.

## Amendment 2026-10-31 (#2441) — §1: build's "test is wrong" answers are code-findings

Build's outputs were all `change`, which test-author does not take (it stays blind to the implementation,
#2022), so an answer from build about a test could not reach the stage that owns it. Build now declares
one more output, `build-tests-result.json` (`build_tests`, topic `code-findings`: what the code or a test
must fix), holding only build's answers that a test is wrong, each naming the test file and why, written
on every try. It follows the review lenses' `lens-<id>-code-result.json`. Test-author takes
`code-findings`, so it is shown them as `build-tests finding <n>`; build's diff and summary stay on `change`.

## Enforced by

- §1 amendment 2026-10-31 (#2441: build's "test is wrong" answers are code-findings) → `tests/unit/build-test-is-wrong-test.sh` W2–W3; `tests/unit/stage-takes-topics-test.sh` T7
- §1 → `plugins/agent/review-lens/tests/review-lens-loop-test.sh` R3 (a lens's findings in one output per topic, by what fixes them); `tests/unit/stage-takes-topics-test.sh` T6 (an unknown topic or take is refused, naming it), T7 (every output of the shipped stages names its topic); `tests/unit/stage-contract-card-test.sh` C2 (an output with a topic and no description is refused), C5 (every shipped output with a topic has a description); `tests/integration/test-checks-own-run-test.sh` R4 (the acceptance check's finding lives only in its own result), R7 (a check that failed with no findings gets its reason as one finding)
- §2 → `tests/unit/stage-takes-topics-test.sh` T1 (only the topics taken: paths, summaries, findings, errors), T2 (no topic → no stage with `takes:`), T3 (no `takes:` → everything), T4 (the changed-files line is a `change`), T5 (own notes), T8 (the dispatch passes the stage's own manifest); `tests/unit/stage-contract-card-test.sh` C1 (a take is `{ topic, for }`; no `for:`, an unknown topic and the one-line form are refused), C3 (Previous work reads the topics), C4 (every taken output's findings, labelled by their output; an untaken output's never), C5 (every shipped take has a `for:`); `tests/integration/test-checks-own-run-test.sh` R6 (design is shown the acceptance check's finding; build is shown it once)
- §3 → `tests/unit/stage-takes-topics-test.sh` T7 (each shipped stage's `takes:`; every stage that composes a model prompt declares one)
- §4 → `tests/unit/stage-takes-topics-test.sh` T1 (a stage that takes a topic with nothing in it is not shown the stage that wrote only other topics)
- §5 → `tests/unit/stage-takes-topics-test.sh` T1 (the findings of a topic not taken are not in the prompt)
