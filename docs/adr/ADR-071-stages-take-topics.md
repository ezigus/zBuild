# ADR-071 — Each output names its topic; each stage takes only the topics it needs

**Status:** Accepted (2026-10-27); amended 2026-11-08 (#2503, §1 §3: one topic, one kind of item — change-findings and test-findings); amended 2026-11-08 (#2491, §1 §3: a lens finding goes by what fixes it, and reaches a stage once; test-author's check findings are requirement-findings); amended 2026-11-06 (#2480, §2: a map group's outputs are read member by member); amended 2026-10-28 (§3: test-author takes requirement-findings); amended 2026-10-30 (#2428, §1 §2: each stage states its contract; every finding a stage takes reaches it); amended 2026-10-31 (#2441, §1: build writes its answers that a test is wrong to its own code-findings output); amended 2026-11-02 (#2452, §1 §2: each finding can carry its own topic); amended 2026-11-02 (#2454, §1 §2: every stage result declares where its findings may go; the test stage labels by whose test it is)
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
   *Amended 2026-11-08 (#2503):* and two that only findings carry, so that no topic holds two kinds of item:
   - `change-findings` — what only the code can fix: a lens's finding the code must fix, a failing file that is not one of the design's tests;
   - `test-findings` — what test-author's own check found wrong in a test against its requirement.
   A finding takes the topic of the output it is in, and lives in one output: a stage does not copy one output's findings into another. *Amended 2026-11-02 (#2452):* a finding may name its own topic, and then goes by it; one that names none goes by its output's (see the amendment below). The words are checked at load: a manifest naming any other topic is refused, naming the word.

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

## Amendment 2026-11-02 (#2452) — §1 §2: each finding can carry its own topic

On #1805 run 41378014898, issue-acceptance found six unmet requirements, five of them code the change
had not done yet. All six sat in its one result, whose topic is `requirement-findings`, and the same
lines were in its summary, so design got all of them. Design spent its whole 20-minute call debugging
the code (155 turns, nothing saved), and the run ended. Only one finding was design's to fix.

- **§1: a finding may name its own topic,** one of the five words. A finding that names none, or names
  any other word, takes its output's topic, as before. Every stage can tag a finding: the shared
  `stage_findings_json` reads a line `<topic><TAB><text>` as a finding with that topic, and
  `stage_findings_lines` reads a result's findings back the same way, so a stage that folds findings
  keeps their topics. This replaces "a finding takes the topic of the output it is in". The lenses' one
  output per topic (amendment 2026-10-30) still works.
- **§2: Previous work shows a finding to a stage that takes the finding's topic,** whichever output holds
  it, labelled as before. Paths, summaries and error logs still go by their output's topic. A finding
  with no topic in an output with no topic reaches no stage that declares `takes:`, as before (§2). A stage that
  sends its findings to more than one topic does not repeat them in its summary, because the summary goes
  to every stage that takes the summary's topic.
- **Who tags what.**
  - issue-acceptance's judge starts each `UNMET:` line with `[fix-code]` (the change does not do it yet:
    `code-findings`) or `[fix-design]` (the requirements miss it or get it wrong, or the issue is wrong:
    `requirement-findings`). Its summary counts the unmet requirements and does not list them.
  - The acceptance check tags as `code-findings` its findings about the code or a test: a test that does
    not pass on the new code, a changed file no test checks, a test that never reached its assertion, a
    test file that died on a signal, a test file too slow to check. Its findings about the requirements
    keep the result's topic.

## Amendment 2026-11-02 (#2454) — §1 §2: every stage result declares where its findings may go

#2452 let a finding name its own topic, but only issue-acceptance and the acceptance check used it, and nothing made a stage decide. On #1805 run 41452299475 the test stage sent all 12 failing test files and 9 shape-check findings to test-author, 7 of the files tests it did not write; it spent its call sorting 27 problems, 5 of them its own.

- **§1: every stage result declares `finding_topics:`.** An output that is a stage result (`primary: true`, or a path ending `-result.json`) names the topics its findings may name for themselves, or `none`. `validate_manifest` refuses a stage result without it, or with a word outside the five, so a new stage, or a new kind of finding, cannot slip through undecided. The shipped declarations: issue-acceptance `code-findings requirement-findings`; the acceptance check `code-findings`; test's result and the shape check `change`; every other stage result `none`.
- **§2: Previous work honours a finding's own topic only when its output lists it;** otherwise the finding goes by its output's topic.
- **The test stage labels by whose test it is.** A failing test file, or a file the shape check says this change must update, that is one of the design's test files keeps the output's topic (`code-findings`: test-author and build). Any other file is labelled `change`, which build takes and test-author and design do not.
- **Each test file is listed once.** `acceptance_list_testfiles` used to print a file once per requirement that named it, and every reader repeated it (test-author's "Already written" list named one file six times).

## Amendment 2026-11-02 (#2458) — §1 §2: design's work steps carry a topic

On #1805 run 41489923219 design's step "add `export _ZBUILD_RESUME_ACTIVE=true` to `resume-loop-state-test.sh`" — one of the design's own test files — was given to build, which may not edit those files, and never to test-author. Build found the code fix, saw it turn that test red, and spent five tries without an edit.

- **Each step in `design-steps.json` carries a topic, from its files.** A step whose files are the design's own test files (its TESTFILES) is `tests`: only the stage that writes the tests may change them. A step on code, or on a test file outside that list (a golden, an older test this change must update), is `change`. A step that touches both is split into one of each, with the same words. The same rule the test stage labels its findings by (#2454).
- **Each stage is shown its own steps.** Build's work plan holds only the `change` steps; test-author's prompt lists the `tests` steps as part of its job. A step written before steps carried a topic counts as `change` (`work_steps_of_topic`).

## Amendment 2026-11-06 (#2480) — §2: a map group's outputs are read member by member

On #1805 run 42229975998 the six review lenses failed in both rounds, and build's Previous work held none of their findings — only the security lens's summary. A map group writes each output once a member (`lens-<id>-code-result.json`), so the output reaches the input index as an array of files. Previous work listed the array's paths but read none of them for findings, and read the summary and result of the first member only; `_summaries_collect` kept the first summary path. Round 1's critical finding never reached build or test-author.

- **Every file of an output is read as a single file is** (`_stage_block_previous_work`, `_sp_output_paths_v`): each member's findings, by the topic its output names (§2, unchanged), labelled by its file — the name `open_items_json` gives it (`lens-correctness-code finding 1`); each member's summary; each member's result for its findings. Nothing is special to the lenses: any map group's outputs are read so.
- **A map group counts as having a summary when any member wrote one** (`_summaries_collect`), not only the first.

## Amendment 2026-11-07 — §5: a finding that does not block still reaches the stages that take its topic

A review lens sent on only the findings at its fail rule's severity. On #1805 run 42374066107 the performance
lens graded "an extra state write each round" low and passed, so no stage was given it; the next round graded the
same finding medium and failed.

- A stage sends on every finding the change introduced, whatever its grade, each with `blocking`: `true` when it is
  at the stage's fail rule, `false` when not. Only a blocking finding fails the stage, or the output it is in.
- Previous work shows one that does not block as `(opened by <stage>, does not block)`. A stage that takes its topic
  answers it like any other (ADR-068 §6).

## Amendment 2026-11-08 (#2491) — §1 §3: a finding reaches the stages that can fix it, once

On #1805 run 42439063480 every lens finding about code reached test-author, which can change no code: a lens put the findings the code must fix and those a test must fix into one output under `code-findings`, which test-author and build both take. Test-author answered the same 11 findings "not mine", then "wrong", then "done" across its three tries. Each also reached it a second time, inside the lens's summary, which lists every finding under the same topic. And test-author's own check found a test could not meet DSCMBR-1's Given, which only design can rewrite; but the check's findings were `code-findings`, and design takes `ask` and `requirement-findings`.

- **A lens finding goes by what fixes it.** The lens's code output lists `change` in `finding_topics`; a finding the code must fix (`fix: code`) names `change`, which build takes and test-author never does. One a test must fix keeps the output's `code-findings`. The lens decides nothing new: it already says what fixes each finding.
- **A lens finding reaches a stage once.** The lens's verdict file, summary and replies name no topic, so they reach no stage that declares `takes:` (§2). Their findings already reach the stages, numbered, from the code and design outputs. The run-status comment reads the summaries by path, as before.
- **Test-author's result is `requirement-findings`** (§1's list: what checks found against the requirements and the design). Its check's findings say a test does not do what its SPEC says; design is shown them, so a Given no test can meet reaches the one stage that can rewrite it. Build still takes them.
- **§3's table is unchanged:** each stage takes what it took; what changes is the topic the findings carry.

## Amendment 2026-11-08 (#2503) — §1 §3: one topic, one kind of item

On #1805 run 42523805245 two topics each carried two kinds of item, so findings reached stages that could not fix them:
- **`change`** was both the diff and the findings the code must fix (#2491 tagged a lens's `fix: code` findings, and the test stage's failing files outside the design's tests, `change`). Issue-acceptance takes `change` for the diff. It was shown all 12 lens findings and told to answer each; in round 1 it answered 16 of them "done", quoting build's fixes, and in round 2 its reasoning spent its time checking them in the code ("to verify the correctness findings") until both calls ran out of time.
- **`requirement-findings`** was both what the code does not meet (issue-acceptance's `[fix-code]` lines, build's to fix) and what test-author's check found wrong in a test (#2491). Build takes `requirement-findings`, so it was shown "DSFRSH-2's test never asserts no stage.skip", a test only test-author may edit.

- **§1: two more topics, carried only by findings.** `change-findings`: what only the code can fix. `test-findings`: what test-author's own check found wrong in a test. `change` is the code the change made, and names no finding.
- **The findings that named `change` name `change-findings`:** a lens's `fix: code` finding (its code output's `finding_topics: change-findings`), and the test stage's failing file that is not one of the design's tests (test's result and the shape check, `finding_topics: change-findings`).
- **Test-author's result is `test-findings`,** not `requirement-findings` (amends #2491's bullet).
- **§3, amended:**

  | Stage | Takes |
  |---|---|
  | design | ask, requirement-findings, test-findings |
  | test-author | ask, tests, requirement-findings, code-findings, test-findings |
  | build | ask, tests, change, requirement-findings, code-findings, change-findings |
  | issue-acceptance, review lenses, monitor | unchanged: none of them takes either new topic |

## Enforced by

- §1 §3 amendment 2026-11-08 (#2503: change-findings and test-findings; one topic, one kind of item) → `tests/unit/finding-goes-to-fixer-test.sh` F5 (a finding the code must fix reaches build, not issue-acceptance), F6 (test-author's check finding reaches design and test-author, not build); `tests/unit/stage-takes-topics-test.sh` T7
- §1 §3 amendment 2026-11-08 (#2491: a lens finding by what fixes it, once; test-author's check findings reach design) → `tests/unit/finding-goes-to-fixer-test.sh` F1–F4; `tests/unit/map-findings-reach-stages-test.sh` M4; `tests/unit/stage-takes-topics-test.sh` T7

- §5 amendment 2026-11-07 (a finding that does not block still travels, marked) → `tests/unit/finding-answers-test.sh` C1, C2; `plugins/agent/review-lens/tests/review-lens-loop-test.sh` R3

- §2 amendment 2026-11-06 (#2480: a map group's outputs are read member by member) → `tests/unit/map-findings-reach-stages-test.sh` M1–M3, M5, M6 (M4 now says no lens summary is shown, #2491)

- §1 §2 amendment 2026-11-02 (#2458: design's work steps carry a topic; each stage is shown its own) → `tests/unit/design-step-topics-test.sh` T1–T4

- §1 §2 amendment 2026-11-02 (#2454: every stage result declares where its findings may go) → `tests/unit/finding-owner-topics-test.sh` O1–O5; `tests/integration/test-checks-own-run-test.sh` R8
- §1 §2 amendment 2026-11-02 (#2452: each finding can carry its own topic) → `tests/unit/finding-topics-test.sh` F1 (a topic before a tab), F2–F4 (Previous work routes each finding by its own topic, else its output's), F5–F6 (issue-acceptance's marks; its summary does not list them), F7 (the acceptance check's code and test findings are code-findings), F8 (findings read back with their topics)
- §1 amendment 2026-10-31 (#2441: build's "test is wrong" answers are code-findings) → `tests/unit/build-test-is-wrong-test.sh` W2–W3; `tests/unit/stage-takes-topics-test.sh` T7
- §1 → `plugins/agent/review-lens/tests/review-lens-loop-test.sh` R3 (a lens's findings in one output per topic, by what fixes them); `tests/unit/stage-takes-topics-test.sh` T6 (an unknown topic or take is refused, naming it), T7 (every output of the shipped stages names its topic); `tests/unit/stage-contract-card-test.sh` C2 (an output with a topic and no description is refused), C5 (every shipped output with a topic has a description); `tests/integration/test-checks-own-run-test.sh` R4 (the acceptance check's finding lives only in its own result), R7 (a check that failed with no findings gets its reason as one finding)
- §2 → `tests/unit/stage-takes-topics-test.sh` T1 (only the topics taken: paths, summaries, findings, errors), T2 (no topic → no stage with `takes:`), T3 (no `takes:` → everything), T4 (the changed-files line is a `change`), T5 (own notes), T8 (the dispatch passes the stage's own manifest); `tests/unit/stage-contract-card-test.sh` C1 (a take is `{ topic, for }`; no `for:`, an unknown topic and the one-line form are refused), C3 (Previous work reads the topics), C4 (every taken output's findings, labelled by their output; an untaken output's never), C5 (every shipped take has a `for:`); `tests/integration/test-checks-own-run-test.sh` R6 (design is shown the acceptance check's finding; build is shown it once)
- §3 → `tests/unit/stage-takes-topics-test.sh` T7 (each shipped stage's `takes:`; every stage that composes a model prompt declares one)
- §4 → `tests/unit/stage-takes-topics-test.sh` T1 (a stage that takes a topic with nothing in it is not shown the stage that wrote only other topics)
- §5 → `tests/unit/stage-takes-topics-test.sh` T1 (the findings of a topic not taken are not in the prompt)
