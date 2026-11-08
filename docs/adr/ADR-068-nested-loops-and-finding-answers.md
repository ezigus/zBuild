# ADR-068 — Nested loops and finding answers: the engine never decides who owns a finding

**Status:** Accepted (2026-10-04); amended 2026-11-08 (#2501, §6: only this reply's answers count; what each answer means); amended 2026-11-08 (#2491, §3: test-author no longer ends the run; §6: no follow-up ask — a finding not answered stays open); amended 2026-11-07 (#2487, §6: an answer names the finding as listed; the follow-up ask in the contract order); amended 2026-10-10 (§1 §8: impact removed from delivery_loop); amended 2026-10-11 (§6–§8: the engine keeps only stage outputs; §8: only each stage's latest output is passed on); amended 2026-10-12 (§8: every stage's latest output, from any run and the stage's own included, goes to every later stage — ADR-067 §8, ADR-050 §9; §1: impact retired from zBuild; §8: loop `feedback:` edges retired); amended 2026-10-18 (§1 §2 §3 §10: design makes one model call per run and keeps its last good design; a design that still fails ends the run — #1944 run 38883031887); amended 2026-10-27 (§6 §8: a stage is given, and answers, only the topics it takes — ADR-071, #1944 run 40393999128); amended 2026-10-28 (§5: a finding is never split); amended 2026-10-31 (§1 §2 §3: design runs in every round of the build loop; only the lenses send the change round again; §6: test-author answers the findings about its tests — #1754 run 41138244027); amended 2026-10-31 (#2441, §6: build may answer that a test is wrong; that answer is a finding for test-author — #1754 run 41208786459); amended 2026-11-03 (#2464, §6 §7: answers are kept in the result; a check keeps a verdict whose inputs are unchanged); amended 2026-11-05 (#2474, §3: a stage can end its loop's round); amended 2026-11-06 (#2480, §8: every member's output of a map group reaches every later stage)
**Issue:** #2271; §8 amended by #2330 (2026-10-06); §1 §8 amended by #1668 (2026-10-10); §6–§8 amended 2026-10-11 (after the #1668 and #1932 runs)
**Supersedes:** ADR-045 (bounded typed backward-route), ADR-061 (fault-class vocabulary)
**Amends:** ADR-021, ADR-027, ADR-040, ADR-046, ADR-047, ADR-054 §4, ADR-055 (finding-owner amendment)
**Related:** ADR-063 §5 (every model-calling stage declares a save-as-you-go output), ADR-066, ADR-067

## Context

Findings went back to the wrong stage regularly. Stages do not know about each other, so the engine guessed who owned each finding:
- **Fault classes:** gates declared `specification` / `scope` / `implementation` (ADR-061), and the gate aggregator rolled them up.
- **`route_back`:** a template edge jumped from the build loop back to the design loop on a fault (ADR-045).
- **Ownership framing:** the summaries later stages read told each stage which findings were "yours to fix" (`finding-owner.sh`, ADR-055 amendment).
- **Escalation ladder:** the acceptance check reclassified a finding as design's from round 2 onwards.

Each misroute was fixed with another rule (#1777, #2157, #1847, #1846). In #2032 run 37066151065 a design-owned WIRING choice went to build and test-author, and test-author "fixed" it with a test that greps a file. Eric (2026-10-03): the routing logic is "much too complicated and wrong".

## Decision

1. **Nested loops, nothing jumps backwards.** The default flow is one outer loop holding design and the build loop (`delivery_loop` in `simple.yaml` and `deployed.yaml`): design → build loop. Design checks its own design (amended 2026-10-15, #2369: the design loop, with design-gate and spec-coverage as its members, is retired; ADR-040, ADR-046). A design that fails is not sent back to the model inside the stage: the engine runs design again (§10, amended 2026-10-18). Plan runs once, before it. The impact stage is retired from zBuild altogether — its plugin, its library and its renderer — not only from the shipped templates (amended 2026-10-12). `route_back` is removed; a template that declares it is refused at load, with an error that says the nested loops replace it.
2. **Inner loops reset each time they start.** Each time the outer loop goes round, the build loop starts again at round 1. Budgets: outer 2, design 3 runs of one model call each (the template's `retry: 2`, §10, amended 2026-10-18), build 3.
3. **An inner loop that ends without converging ends the outer round.** This applies when the inner loop declares `on_max: halt`, or runs out with tests failing. A member the outer loop names in `stop_run_on_fail:` that does not pass ends the run, failed, naming the member (amended 2026-10-15, #2369; amended 2026-10-18 from `stop_round_on_fail:`, which went round again). `delivery_loop` names `design`: build never runs on a design that still fails its checks, and the loop does not go round, because the engine has already run design as often as the template allows (§10) — another round would only repeat those tries. #1944 run 38883031887 made 12 design calls over two rounds that way. The template names the members; a member it does not name never ends the run. When the outer rounds are spent, the outer loop's own `on_max` applies, and in the default flow the run stops. An inner loop with `on_max: continue` keeps ADR-019's fall-through. A member whose result halts the run (`broken`, `misconfigured`) inside an inner loop ends the run there, with the member's own reason, and the outer loop does not go round (amended 2026-10-26): #1801 run 40390919951's test stage was `broken`, the outer loop went round anyway, and design was then named as the cause.
4. **An outer loop's multi-condition `exit_when` is its own.** Running an inner loop never changes how the outer loop's exit is evaluated.
5. **Every check lists its findings as numbered items** (`data.findings: [{n, text}]`) in plain sentences (ADR-067). Identity comes from where a finding already lives: the stage's result, item n. Later stages see each finding on its own line: `- <stage> finding <n> (opened by <stage>): <text>`. Each finding is one whole item: a check never splits one finding's text into several (amended 2026-10-28: issue-acceptance split its model's answer at every `;`, so on #1944 a finding whose prose held one became fragments such as "…" and "set -e` mid-file)").
6. **Every stage says, in its own result, what it did about each finding it receives** (amended 2026-10-11; 2026-10-12; 2026-10-27: it receives only the findings of the topics it takes, ADR-071): it answers a finding only with what goes into the output its What you own section names, and anything the finding would need beyond that output it says, and does not do. A stage's job is its What you own section, nothing more (ADR-067 §8). #1801's rerun showed why: plan was handed failing tests and spent every call debugging them, the work of the stage that changes code, and never wrote a plan. The engine's rules for every stage say so (Rules for this stage, `scripts/lib/stage-prompt.sh`, ADR-067 §8). The reply is part of the stage's output and reaches later stages the way any output does. Build keeps its own report of a failing test it ran and saw pass (`ANSWER <stage> finding <n>: nothing to do — not reproduced: <path>`), which build itself reads (#2322).
7. **A check closes a finding by not listing it again** (amended 2026-10-11). Each time a check runs it judges the work fresh and lists what it finds; its newest list replaces its old one. Numbers only have to be unique within one list.
8. **The engine keeps nothing but each stage's output, and moves on by the template's rules** (amended 2026-10-11). It passes each stage's output to later stages — to a stage that declares `takes:`, only the outputs whose topic it takes (amended 2026-10-27, ADR-071) — keeps no record of its own beside them, and judges nothing a stage wrote. A loop goes round until its exit condition passes or its rounds run out; then its `on_max` applies. A stage's error log holds only its latest dispatch's errors: the engine empties it as each dispatch starts, and the attempt archive keeps the earlier ones (amended 2026-10-14, #1801 rerun).
   - **Why amended:** the engine used to keep its own record of which stage answered which finding, across rounds, and count it (`unowned: yield | halt`, `core/pipeline/unowned.sh`, `<state>/finding-answers/`). Finding numbers restart each time a check runs, so in #1668's run an answer from one round was counted against a different finding in the next, and the stop report printed a finding with no words. `unowned:` is removed; a template that declares it is refused at load, with an error that says what replaces it.
   - **Only each stage's latest output is passed on; earlier versions of it are not** (amended 2026-10-11). This holds for every stage and wherever it sits in a loop. The latest output is the file the stage wrote, and the engine neither copies it nor deletes it. (a) The orchestrator copies nothing between tries; a loop's `feedback:` edge, which only declared that an output flows back, is retired and refused at load (amended 2026-10-12, ADR-055 §4) — every stage already gets every stage's latest output. In #1932's run the copy taken as design's second try began was handed to spec-coverage and design-gate, so they judged the design design had already replaced and the loop ran out of tries with the fix sitting in `design.md`. (b) A loop no longer deletes a stage's result before running the stage again. A result older than the stage's latest run (`runtime/dispatched/<stage>`, marked by `plugin_hook_call` before anything can refuse the run) is read as absent, so a run that wrote none is never credited with the previous run's verdict. Every reader of a stage's result asks one check, `stage_result_is_current` (`scripts/lib/stage-dispatch-mark.sh`): the result reader, the stage report, `build_kind`, and gate-aggregator. (c) The attempt record (`artifacts/attempts/`) is the run's record of each try, for people. No stage input and no prior-output read resolves to it. (d) A prior design is labelled "written earlier in this run" whenever this run wrote it, any try and any round.
   - **What is given up:** a finding no stage can act on is no longer stopped early. It circles until the loop budgets run out (§2), and the run then stops on the checks' latest results.
   - **What is still open** when a run ends is read from the checks' latest results: every check whose result did not pass, each of its numbered findings, or its reason when it has none (`open_items_json`). Nothing is kept beside those results.
   - **Every report names each open item in plain words (#2330).** Every place a run reports how it ended or what is still open — the issue completion comment, the live status comment, the end-of-run banner and the runner's last lines, and each finding written for the next round — names each item: what is unresolved and what would settle it (the concrete check, evidence or change that would close it). A finding may say what would settle it itself, after `What would settle it:`; otherwise the report says that its check no longer reporting it settles it. The words never contain the engine's codes or numbers (`max_iterations`, `unowned`, yield, halt, `disposition`, raw verdict codes, rc numbers) and never say who must act ("a person must check"): the reader may be a person, an agent or a later run, so they say what must be checked. Events keep their machine codes.
9. **No fault classes.** No stage writes a `fault`, the gate aggregator rolls none up, and rc 11 is retired from the engine's vocabulary (ADR-054 §4).
10. **Design makes one model call per run, and design.md is always its last good design** (amended 2026-10-18). #1944 run 38883031887 made 12 design calls and wrote nothing: each call started from the same prompt, because a call that ran out of time deleted design.md, so the last good design never reached the next try.
   - **One call.** A repeat inside the stage starts from the same prompt and learns nothing. Design's check-and-fix rounds and its call loop are removed. When design's run fails, the engine runs it again (the template's `retry:`), and that run is handed the failure and the last good design.
   - **A working copy.** The model writes `design-draft.md`. A copy that passes design's checks replaces `design.md`; any other result leaves `design.md` as the last good design. A copy that failed stays, and the next run starts from it, told it was rejected and why (its result's findings, under Previous work). With no rejected copy, the working copy starts as a copy of the last good design, so a design is on disk from the first turn.
   - **Any failure is run again.** A design that fails its checks is `unusable`, as a call that ran out of time is `timed_out`; both are run again. The engine's own rule still applies: it runs a stage again only while the last try changed something (ADR-054 §6), so a try that wrote nothing at all is not repeated.
   - **Only findings design can fix.** Design answers a finding only if changing the design (its acceptance contract or its scope) would fix it. It leaves the rest — a bug in the code, a test that does not run — and does not investigate them, and says in its design which it left and why.

### Amendment (2026-10-31) — design runs in every round of the build loop

#1754's run (41138244027) showed the nested shape never reached design: a finding only design could fix
(six files the requirement needs, outside its scope) went to build, which could not fix it, and design
would only run again after the build loop's 3 rounds — about 9 hours at that run's pace, past the job's
6. The engine still never decides who owns a finding (§8); design is simply in every round.

- **§1, amended:** the build loop is **design, build, test** — `build_test_cycle` runs design first, then
  the stages that write and check the change (simple.yaml: design, test-author, build, test,
  issue-acceptance; deployed.yaml: design, build, test). `delivery_loop` holds `build_test_cycle`, then
  the review lenses. Each round design is shown every finding on the topics it takes and answers only
  those a change to the design would fix (§10).
- **§2, amended:** budgets: the build loop 3 rounds; `delivery_loop` 2, so the lenses can send the change
  round once more (the build loop starts again at round 1, as before).
- **§3, amended:** a member a loop names in `stop_run_on_fail:` ends the **run** — an inner loop as much
  as a stage. `build_test_cycle` names design (a design that still fails ends the run, as before), and
  `delivery_loop` names `build_test_cycle`: a build loop that ends without passing ends the run; only the
  lenses send the change round again. The run's reason names the member that stopped it; when an inner
  loop stopped on a member it names, that member.
- **§6, amended:** test-author is told that findings from other stages about its tests are its own — a
  test that already passes on the code from before the change, a test that fails on the new code, a test
  that flags code that already meets its requirement, a test file far slower than the rest — and answers
  each on its own line (`ANSWER <stage> finding <n>: …`). Its answers are in its result (`data.answers`)
  and its summary. On #1754's run it was shown the test stage's findings and fixed only its own check's.

## Consequences

- The engine loses the fault vocabulary (`core/pipeline/fault.sh`), the ownership resolver (`core/pipeline/finding-owner.sh`), the `route_back` parser, validator and runner rewind, the cycle's early-rewind and fallback logic, and the acceptance check's iteration-numbered escalation.
- The engine keeps nothing but stage outputs (§8, amended 2026-10-11): the answer counting that briefly replaced the ownership resolver (`core/pipeline/unowned.sh`, `scripts/lib/stage-answers.sh`) is removed with it.
- A finding a stage misjudges as its own, or that no stage can act on, circles at most until the loop budgets run out.

## Implementation Notes

- `scripts/lib/run-open-items.sh` (#2330): the open items every report lists (`open_items_markdown`), read from the checks' latest results, the end reason in words (`run_end_words`), and the completion comment (`run_completion_body`). The status comment (`run-status-render.sh`), the end-of-run banner (`runner.sh`) and the two workflows read them.
- `scripts/lib/stage-conduct.sh`: the shared prompt part that asks every stage to say in its own result what it did about each finding.
- `scripts/lib/stage-summary.sh` `stage_findings_json`: every check writes `data.findings` through it.
- `core/pipeline/input-resolve.sh`: lists each finding with its opener and gives every reader one framing.
- `core/pipeline/cycle-orchestrator.sh`: the end-of-round rule for nested loops, and rc 5/9 passing straight up from an inner loop. **(superseded 2026-10-08 by ADR-054 §4 / #1850 — now rc 1 + `_CYCLE_LAST_OUTCOME=interrupted` (`blocked`) / `aborted` (abort word `llm_unavailable` / `llm_rate_limited`))**
- `core/pipeline/template.sh`: the `unowned:` and `route_back` refusals (`UO` / `RB` rows), the flow-ordered stage list, and the loop validator over each loop's full expansion.
- An inner loop that is blocked (rc 5) **(superseded 2026-10-08 by ADR-054 §4 / #1850 — now rc 1 + `_CYCLE_LAST_OUTCOME=interrupted`)** or whose model call is unavailable or rate-limited (rc 9) **(superseded 2026-10-08 by ADR-054 §4 / #1850 — now rc 1 + `_CYCLE_LAST_OUTCOME=aborted`, abort word `llm_unavailable` / `llm_rate_limited`)** stops the run rather than going round; going round would only repeat it.

## Amendment 2026-10-31 (#2441) — §6: build can say a test is wrong

On #1754 (run 41208786459) the SPEC-4 test could never pass: its fake skipped every path holding
"intake-result", and the test ran in a folder named `plugin-intake-result.*`. Build saw it fail on code
that did what the requirement said, may not edit a test, and had no answer for it — it spent 12 model
calls debugging it. Now build answers such a finding `ANSWER <stage> finding <n>: nothing to do — the test
is wrong: <test file>: <why>` and stops working on that test. Those answers are findings, in build's own
output `build-tests-result.json` on topic `code-findings` (ADR-071 §1), which test-author takes; fixing or
answering a finding about its tests is test-author's job (§6, amended 2026-10-31). Test-author is never
shown build's code: that stays on `change`.

**Amended 2026-11-01 (#2443):** build gives that answer as soon as it is sure, not after more work on the
test. On #1754 (run 41249802310) round 1's build spent 3 tries of 15 minutes on the test without ever
answering; round 2's build answered, and test-author fixed the test in round 3.

## Amendment 2026-11-01 (#2445) — §6: test-author's tests are run by its script, not its model

#2441 had test-author's model run its own test files — a model judging for itself whether its tests fail,
which nothing checked. Now the model writes tests and runs nothing. After the call, test-author's own script
runs the test files that call created or changed — and any file the last round found something in — on the
code from before this change (the merge-base, with the test files laid over it). A test for a `[code]`
requirement that passes there, a file that stops before a requirement's assertion runs, and a requirement
whose testfile holds no assertion that ran are findings; they go back to the model with its check's
findings, within its rounds. The prompt lists, found by script, each testfile and the requirements whose tag
it already holds, and says that when every requirement has its test and nothing is open for it, it confirms
them and ends.

## Amendment 2026-11-03 (#2464) — §6: every answer is kept in the result; §7: a check keeps a verdict whose inputs are unchanged

- **§6:** a stage's `ANSWER <stage> finding <n>: …` lines are kept in its result as `data.answers`. build and design keep them too, as test-author already did. Design may answer a finding of its own check. A "nothing to do" answer sends that finding back to its judge (ADR-072 §5).
- **§7:** a check still lists what it finds each time it runs, and its newest list replaces its old one. But an item whose inputs are unchanged — what the judge was shown, the files it read, the engine, and the answers to its findings — keeps its last verdict without a model call (ADR-072 §4). On #1805 run 41643063636, test-author's check called BNDY-1 "corresponds" twice and then "partial" on unchanged test files, and that flip ended the run.

## Amendment 2026-11-05 (#2474) — §3: a stage can end its loop's round

#1805 run 42090130741: test-author found a SPEC no test can prove. Only design can rewrite it, and design is the first stage of the same loop, but the finding halted the run.

- **A stage whose finding only an earlier stage of its loop can fix ends the round.** Its result says `outcome: fail` and `data.ends_round: true`. The engine skips the rest of that round, emits `cycle.member.ends_round`, and the loop starts its next round from the top, where the finding reaches every stage as findings do (§5, §6).
- **Nothing jumps backwards (§1).** The stage does not name a stage to go to: the round only ends sooner. The loop's round limit and its `on_max` apply as before.
- **It is read before the blocking rule.** A blocking stage that ends the round does not end the run; one that fails without `ends_round` still does. `ends_round` on a stage that passes changes nothing.

## Amendment 2026-11-06 (#2480) — §8: every member's output of a map group reaches every later stage

§8 says every stage's latest output reaches every later stage. A map group's output is one file a member, and only the first member's summary and none of their findings were passed on (#1805 run 42229975998: build never saw the correctness lens's critical finding). Each member's output now reaches every later stage that takes its topic, exactly as a single stage's does (ADR-071 §2, amended 2026-11-06).

## Amendment 2026-11-07 — §6: every finding a stage is given gets one of three answers, and the engine asks for a missing one

On #1805 run 42374066107 the lenses' code findings went to test-author and to build, which both take
`code-findings`. test-author answered each "nothing to do — fix: code, not in test scope", meaning they were not
its to fix. The engine read every "nothing to do" as a dispute, and told each lens that a stage that had to act on
its findings said they were wrong. Build answered all thirteen in prose ("Security-1 …"), so the engine kept none of
them, and its two disputes never reached red-team.

- **An answer is one of three.** `ANSWER <stage> finding <n>: done — <what changed>`, `wrong — <why it does not
  hold>` or `not mine — <why the stage's job cannot fix it>`. The engine reads the word (`zb_answer_kind_v`); "nothing
  to do", or any other, is no answer. Only a `wrong` answer goes back to the stage that raised the finding
  (`judge_answers_to_v`); `done` changed what is judged, and `not mine` says nothing about the finding. Build's
  "not reproduced" and "the test is wrong" are `wrong` answers. The lint refuses a prompt that still offers
  "nothing to do".
- **Every finding is answered.** Every call that does a stage's work is told the three forms; a judging call is
  not. Design, test-author, build and issue-acceptance hand their prompt and reply to `zb_answers_finish`: each
  finding the prompt showed (`- <label> finding <n> (opened by …)`) that the reply does not answer is asked for
  once, in a call shown the findings and the reply, which may only read files. The result keeps every answer,
  `findings_shown`, and `unanswered` for any still missing; the summary lists each answer, each one not answered,
  or that no finding was open (`zb_answers_summary_v`).
- **§8 still holds.** #2355 removed a rule telling every stage to fill in answer lines: the engine then kept its own
  record of the answers beside the stage outputs, and counted them across rounds. Here the answers are the stage's
  own result, the latest replaces the last, and the engine keeps nothing beside them; it asks only for an answer
  missing from the reply it was given.

## Amendment 2026-11-07 (#2487) — §6: an answer names the finding as it is listed, and the engine's follow-up ask reaches the model

On #1805 run 42397891946 no stage's answers counted. The form said `ANSWER <stage> finding <n>`, and a finding is listed as `lens-sre-code finding 2 (opened by review_lenses)`: design wrote `review_lenses finding 1`, test-author and build `review_lenses finding lens-sre-code finding 2`. All 11 of build's answers were read as missing. The ask for missing answers was plain text, so the router refused it (ADR-067 §8) after every stage.

- **The form names the finding as its line begins:** `ANSWER <the finding as listed>: done | wrong | not mine — …`, in every prompt that asks for answers.
- **An answer with the opening stage's name in front counts** for the finding it names.
- **The follow-up ask is composed in the contract order** (`stage_prompt_compose_text --fresh`), as a judging call.

## Amendment 2026-11-08 (#2491) — §3: test-author no longer ends the run; §6: no follow-up ask

On #1805 run 42439063480 test-author spent its three tries on DSCMBR-1, whose Given says the saved state records "in-progress" while the engine writes `aborted`. Test-author was blocking, so the run ended `out_of_tries:build_test_cycle` in round 1, and design never got the round that would let it rewrite the Given. The same run spent $2.43 on calls that asked a stage for answers it had left out; in two of them the answers were there, written as the finding is listed, "(opened by …)" and all, and the reader did not take them.

- **§3: test-author is not blocking** (ADR-013, amended). Out of tries, the round goes on with the tests as they are — build, test and issue-acceptance run — and the round fails, since test-author did not pass. The loop's next round starts from design, which is shown what test-author's check found (ADR-071 §1, amended). A design that fails still ends the run (`stop_run_on_fail: [design]`).
- **§6: nothing is asked again.** A stage's answers are read from its reply, as before: `done`, `wrong` or `not mine`, `not mine` for a finding its job cannot fix. A finding it does not answer is named in its result's `unanswered` and its summary, stays open, and is shown again next round. The 2026-11-07 amendment's follow-up call, and #2487's form for it, are removed. Every prompt says a finding not answered stays open.
- **§6: the finding as listed counts.** An answer that names the finding with "(opened by …)" after it, as it is listed, counts for that finding, as one with the opening stage's name in front does (#2487).

## Amendment 2026-11-08 (#2501) — §6: only this reply's answers count, and what each answer means

On #1805 run 42488374386 build was shown 11 lens findings in two build rounds and answered none of them: its earlier output, from the previous run, held answers to all 11, and its reasoning said one "was answered 'done' in the build stage summary". The engine reads answers only from the current reply (§6, #2491), so all 11 stayed open. In the same run "not mine" was used for things that are no other stage's work: design wrote "not mine — … No design change is required"; build wrote it 9 times, for a finding that needs no change ("a micro-optimization; no acceptance requirement governs it"), for a fix that needs a file outside its scope list (`config/event-schema.json`, which build may ask for, ADR-030), and for a function its own code does not source.

- **Only this reply's answers count.** Every working stage is told to answer every finding listed, even one it answered in an earlier reply or a past run.
- **What each answer means**, in the same instructions:
  - `done` — the stage changed its output for it;
  - `wrong` — it does not hold, or it needs no change, and why;
  - `not mine` — it holds and needs a change, and that change is to another stage's output.
- **A finding about a stage's own output is that stage's**, even when its fix is outside the issue's requirements or needs a file the stage may not touch: it fixes it, or answers `wrong` and says why it needs no change. A file it may not touch it asks for the way its own instructions say (build: its `BLOCKED: … requires <file> (out of scope)` line, ADR-030).

## Enforced by

- §6 amendment 2026-11-08 (#2501: only this reply's answers count; what each answer means; a finding about your own output is yours) → `tests/unit/finding-answers-test.sh` A4, A5
- §3 amendment 2026-11-08 (#2491: test-author out of tries does not end the run) → `tests/integration/test-author-out-of-tries-goes-on-test.sh` T1–T3; `tests/unit/test-author-test.sh` SPEC-7
- §6 amendment 2026-11-08 (#2491: nothing asked again; the finding as listed counts) → `tests/unit/finding-answers-test.sh` B1–B4, D1, D2

- §6 amendment 2026-11-07 (#2487: the finding as listed; the opening stage in front) → `tests/unit/finding-answers-test.sh` A3, B5, D1, D3 (its follow-up ask removed by #2491)

- §6 amendment 2026-11-07 (three answers; every finding answered) → `tests/unit/finding-answers-test.sh` A1–A3, B3, B5; `tests/unit/design-stage-ids-test.sh` E5, E6; `tests/unit/test-author-checks-own-output-test.sh` A12, A13; `tests/unit/issue-acceptance-test.sh` SPEC-14; `tests/unit/judge-kept-test.sh` K3, K5–K8; `tests/unit/build-prompt-summary-marker-test.sh` M3, M7; `tests/unit/lint-plain-prompts-test.sh` P12; `tests/unit/engine-keeps-only-stage-outputs-test.sh` K5

- §8 amendment 2026-11-06 (#2480: every member's output of a map group reaches every later stage) → `tests/unit/map-findings-reach-stages-test.sh` M1–M6

- §6 §7 amendment 2026-11-03 (#2464: answers kept in the result; a verdict kept while its inputs are unchanged) → `tests/unit/judge-kept-test.sh` K1–K8; `tests/unit/design-stage-ids-test.sh` E5
- §6 amendment 2026-11-01 (#2445: test-author's tests run by script on the old code; the written-tests list) → `tests/unit/test-author-before-run-test.sh` B1–B7; `tests/unit/test-author-loop-test.sh` A1

- §6 amendment 2026-10-31 (#2441: build can say a test is wrong) → `tests/unit/build-test-is-wrong-test.sh` W1–W3; `plugins/agent/build/tests/build-test-is-wrong-run-test.sh`; `tests/unit/test-author-checks-own-output-test.sh` A10
- §6 amendment 2026-11-01 (#2443: build answers as soon as it is sure) → `tests/unit/build-test-is-wrong-test.sh` W4
- §1 (impact retired from zBuild) → `tests/unit/retired-impact-review-report-inputs-test.sh` RT1
- §1 → `tests/unit/no-fault-routing-test.sh` R1 (a template with `route_back` is refused, and the error says what replaces it); `tests/unit/template-simple-yaml-test.sh` SPEC-18 (delivery_loop flow is build_test_cycle,review_lenses), SPEC-14 (build_test_cycle starts with design); `tests/integration/deployed-template-e2e-test.sh` (deployed.yaml's loops)
- Amendment 2026-10-31 §1, §2, §3 → `tests/unit/template-simple-yaml-test.sh` SPEC-14, SPEC-15, SPEC-18 and the deployed.yaml block (ADR-068 §1–§3); `tests/integration/stop-run-on-fail-test.sh` R5 (a design that fails inside the build loop ends the run), R6 (a build loop that does not pass ends the run after 3 rounds, with no review), R7 (the lenses send the change round once more), R8 (and the run stops when they fail again)
- Amendment 2026-10-31 §6 → `tests/unit/test-author-checks-own-output-test.sh` A10 (findings about its tests are its own), A11 (expected to fail on the code from before the change), A12 (its answers are in its result and summary)
- §1, §2 (design checks its own design, #2369; no round inside the stage, 2026-10-18) → `tests/unit/design-checks-own-output-test.sh` C1–C5
- §3 (`stop_run_on_fail:`, #2369, 2026-10-18) → `tests/integration/stop-run-on-fail-test.sh` R1–R4
- §2, §3, §4 → `tests/integration/nested-loop-rounds-test.sh` L1, L2, L4, L5; `tests/integration/nested-loop-rounds-build-test.sh` L3, L6, L7 (a member that halts the run inside the build loop stops it, naming what the member said); `tests/integration/cycle-member-dispatch-events-test.sh` §3 (rc 8 still halts on the last outer round); `tests/integration/cycle-rate-limit-aborts-run-test.sh` (rc 9 from an inner loop ends the run)
- §5 → `tests/unit/numbered-findings-test.sh` N1–N5; `tests/unit/issue-acceptance-test.sh` SPEC-10 (a finding is never split, 2026-10-28)
- §6, §8 (2026-10-27: only the topics a stage takes) → `tests/unit/stage-takes-topics-test.sh` T1–T5, T8
- §6 → `tests/unit/engine-keeps-only-stage-outputs-test.sh` K2 (no request to fill in answer lines reaches a prompt), K5 (every stage is told, in the engine's rules, that its job is its What you own section and its result the output it names: each finding answered only with what goes into that output, the rest said, not done)
- §6 (build's own not-reproduced report) → `tests/unit/build-prompt-summary-marker-test.sh` M7; `tests/unit/build-scope-request-evidence-test.sh` E7 (build reads the path it ran from its own report)
- §7 → `tests/unit/numbered-findings-test.sh` N1–N5 (each check's result lists its findings afresh)
- §8 → `tests/unit/engine-keeps-only-stage-outputs-test.sh` K1 (a template that declares `unowned:` is refused, and the error says what replaces it), K3 (a reply's answer lines leave no record in the state directory), K4 (open items come from the checks' latest results, never a record kept beside them); `tests/integration/nested-loop-rounds-test.sh` L1, L2 (a loop goes round until it passes or its rounds run out)
- §8 (2026-10-12: every stage's latest output, any run, its own included, reaches every later stage) → `tests/unit/stage-prompt-contract-test.sh` P1, P2; `tests/unit/stage-input-resolve-test.sh` SPEC-1
- §8 (a stage's error log holds only its latest dispatch's errors) → `tests/integration/stage-errors-log-per-dispatch-test.sh` E1
- §8 (only each stage's latest output is passed on) → `tests/unit/stage-input-resolve-precedence-test.sh` SPEC-4 (on a loop's second try the consumer reads its producer's rewritten output, not the try-start copy); `tests/unit/stage-latest-output-test.sh` L1, L1b (a run that did not rewrite its result has none; the engine deleted nothing), L2 (a loop does not delete a member's output before re-running it), L3 (gate-aggregator counts a gate that wrote nothing this run as missing), L4, L5 (the stage report and `build_kind` come only from this run's result), L6 (a run refused before its hook ran has no result either); `tests/unit/own-run-artifacts-first-test.sh` O1, O6, O11 (the attempt record is never an input); `tests/unit/prior-output-reader-test.sh` T1, T5; `tests/unit/design-prior-hypothesis-test.sh` SPEC-5, SPEC-5b (design refines this run's own design on any try and any round)
- §8 (plain words in every report, #2330) → `tests/unit/run-open-items-test.sh` O1 (failing checks listed, each with what would settle it), O3 (the end reason in words), O4 (the completion comment), O5 (the status comment), O6 (the end-of-run banner), O7 (guard: no internal term, code, number or "a person"/"human"), O8 (the workflows build the completion comment from these words), O9 (the runner's last lines); `tests/unit/issue-acceptance-status-test.sh` I2 (the finding for the next round says what would settle it, never who must check it)
- §9 → `tests/unit/no-fault-routing-test.sh` R2–R4; `tests/unit/dispatch-rc-test.sh` SPEC-5 (rc 11 retired)
- §10 → `tests/unit/design-one-call-keeps-last-good-test.sh` D1 (one call), D2 (a failed check is `unusable`, with its findings), D3, D4 (a failed try or a timeout leaves the last good design.md), D5 (the model writes the working copy, which starts as the last good design), D6 (a passing design replaces design.md), D7 (a rejected try comes back as rejected, with its result), D8 (only findings a design change would fix), D10 (each shipped template: `retry: 2` and `stop_run_on_fail: [design]`); `tests/unit/design-call-timeout-test.sh` SPEC-1, SPEC-2 (a call out of time keeps the last good design and is `timed_out`)
- Amendment 2026-11-05 §3 (a stage ends its loop's round, #2474) → `tests/integration/cycle-member-ends-round-test.sh` E1–E5; `tests/unit/gwt-judges-test.sh` T8 (test-author's untestable SPEC ends the round)
