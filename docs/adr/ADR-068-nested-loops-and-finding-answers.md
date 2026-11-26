# ADR-068 — Nested loops and finding answers: the engine never decides who owns a finding

**Status:** Accepted (2026-10-04); amended 2026-11-26 (#2614, §3: a stage marked not blocking is not part of `requires: all`); amended 2026-11-22 (#2586, §6: a plain "wrong" does not close a finding the final judge still holds; §8: the open items include every stage's failed checks); amended 2026-11-20 (#2574, §5 §6: a finding has a stable id, and an answer names it and carries the finding's text); amended 2026-11-20 (#2569, §8: design refines its newest try; its last good output is the newest passing one); amended 2026-11-19 (#2567, §6: every claim a stage makes is read by some check); amended 2026-11-18 (#2565, §6: build answers each design step as it answers each finding); amended 2026-11-16 (#2554, §6: the before-run says only that no tagged line appeared); amended 2026-11-12 (#2527, §6: build's "the test is wrong" answers are read by the one answer reader); amended 2026-11-09 (#2506, §6: test-author runs nothing but a failing test of its own; build's "the test is wrong" wins over "fix your code"; a failed stage shows what failed when it ran); amended 2026-11-08 (#2503, §6: test-author runs a failing test before changing it; build says a test is wrong on a check); amended 2026-11-08 (#2501, §6: only this reply's answers count; what each answer means); amended 2026-11-08 (#2491, §3: test-author no longer ends the run; §6: no follow-up ask — a finding not answered stays open); amended 2026-11-07 (#2487, §6: an answer names the finding as listed; the follow-up ask in the contract order); amended 2026-10-10 (§1 §8: impact removed from delivery_loop); amended 2026-10-11 (§6–§8: the engine keeps only stage outputs; §8: only each stage's latest output is passed on); amended 2026-10-12 (§8: every stage's latest output, from any run and the stage's own included, goes to every later stage — ADR-067 §8, ADR-050 §9; §1: impact retired from zBuild; §8: loop `feedback:` edges retired); amended 2026-10-18 (§1 §2 §3 §10: design makes one model call per run and keeps its last good design; a design that still fails ends the run — #1944 run 38883031887); amended 2026-10-27 (§6 §8: a stage is given, and answers, only the topics it takes — ADR-071, #1944 run 40393999128); amended 2026-10-28 (§5: a finding is never split); amended 2026-10-31 (§1 §2 §3: design runs in every round of the build loop; only the lenses send the change round again; §6: test-author answers the findings about its tests — #1754 run 41138244027); amended 2026-10-31 (#2441, §6: build may answer that a test is wrong; that answer is a finding for test-author — #1754 run 41208786459); amended 2026-11-03 (#2464, §6 §7: answers are kept in the result; a check keeps a verdict whose inputs are unchanged); amended 2026-11-05 (#2474, §3: a stage can end its loop's round); amended 2026-11-06 (#2480, §8: every member's output of a map group reaches every later stage)
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
output `build-tests-result.json` on topic `code-findings` (ADR-071 §1; `test-findings` since #2569), which test-author takes; fixing or
answering a finding about its tests is test-author's job (§6, amended 2026-10-31). Test-author is never
shown build's code: that stays on `change`.

**Amended 2026-11-01 (#2443):** build gives that answer as soon as it is sure, not after more work on the
test. On #1754 (run 41249802310) round 1's build spent 3 tries of 15 minutes on the test without ever
answering; round 2's build answered, and test-author fixed the test in round 3.

## Amendment 2026-11-01 (#2445) — §6: test-author's tests are run by its script, not its model

#2441 had test-author's model run its own test files — a model judging for itself whether its tests fail,
which nothing checked. Now the model writes tests and runs nothing (amended 2026-11-09, #2506: nothing but a test file of its own that it is told fails). After the call, test-author's own script
runs the test files that call created or changed — and any file the last round found something in — on the
code from before this change (the merge-base, with the test files laid over it). A test for a `[code]`
requirement that passes there, and a test file whose output holds no line tagged for a requirement, are
findings (amended 2026-11-16, #2554: the finding says only that no line tagged `[<id>]` appeared — it reads
no exit code and guesses no cause, ADR-069); they go back to the model with its check's
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

## Amendment 2026-11-08 (#2503) — §6: test-author runs a failing test before changing it; build says a test is wrong on a check

On #1805 run 42523805245 a test's mock intake plugin had no role, so the mocked pipeline stopped at intake and "the cycle stage emits cycle.start" failed: expected >0, got 0.
- **Test-author** was told the test failed and never ran it. It guessed the engine does not do this yet, and deleted the assertion. Its own check then said the assertion was missing, and it went back and forth for the rest of the round.
- **Build** set its change aside (`git stash`) and saw the test fail the same way, then twice found the cause ("the mock doesn't have `role: intake`"). Both times it went on checking whether its own change caused it, and ran out of time without answering.

- **Test-author:** when it is told a test of its fails, it runs that test file and finds out why before it changes it. It fixes what is wrong, and never deletes an assertion to make a test pass.
- **Build:** a test is wrong by a check, not a feeling. If the test fails the same way with build's change set aside, build's change did not cause it: build finds what in the test makes it fail, answers `the test is wrong` (§6, #2441), and stops working on it.

## Amendment 2026-11-09 (#2506) — §6: the prompts stop contradicting themselves

On #1805 run 42556446368 two stages were each told two opposite things, and one was told something false.

- **Test-author** was told to run a test of its that it is told fails (#2503), and to "run nothing" (#2445). It ran no test in all four calls. Now it may run a test file of its own that it is told fails — only that file, never the suite or lint — and its script still runs the test files it created or changed on the code from before this change. ADR-067 §8 says the same (amended the same day).
- **Build** was told it may answer "the test is wrong" after setting its change aside (#2441, #2503), and, in What you must not do, "A failing assertion means YOUR CODE is wrong — fix the code" (#2022). It saw the test's fake plugin had no role, and changed the engine instead. Now that sentence says: when an assertion fails, fix your code; if it fails the same way with your change set aside, the test is wrong — answer as "When a test is wrong" says, and do not edit it. Build still may not edit a test.
- **Build** was told "A failed stage under Previous work is red RIGHT NOW on this tree", and that the listed tests "fail on the code as it is now; do not run them to find that out". That is false whenever the code changed after the test stage ran: at the start of every rerun, and after test-author changes a test. Now a failed stage under Previous work shows what failed when that stage ran; build runs that one test file once, before it works on it, to see whether it still fails.

## Amendment 2026-11-09 (#2508) — §8: a failed run's report shows the questions design could not settle

A run that fails ends by naming each open item (§8, #2330). It now also shows each question design wrote and could not settle, with the assumption it went on with (ADR-069, amended 2026-11-09): the end-of-run banner and the issue's completion comment, which reads the same list through `open_items_outbound` and so is cleaned by the scope redactor the same way. The question is part of why the run may have gone wrong, and the reader of the report is the one who can answer it. The words are those of the run-status comment (ADR-064, amended 2026-11-09), from the one reader.

## Amendment 2026-11-12 (#2527) — §6: build's "the test is wrong" answers are read by the one answer reader

On #1805 run 43130129438 build answered "the test is wrong" in rounds 1 and 2, naming the finding as it was listed: "issue-acceptance finding 1 (opened by issue-acceptance)". The reader that turns those answers into findings for test-author had a pattern of its own that did not take the "(opened by …)" part, so neither answer reached test-author. #2491 had already taught the answer reader (`zb_answers_collect_v`) to take it.

- **§6: build's answers that a test is wrong, or must change, are the answers `zb_answers_collect_v` reads** (`_build_test_wrong`, `plugins/agent/build/lib/summary.sh`). There is one reader of a stage's answers, so a finding named in any form it takes is read the same way everywhere.

## Amendment 2026-11-14 (#2543) — §3: an inner loop out of rounds on a finding for an earlier member does not end the run

On #1700 run 43617030653 the build loop ran out of rounds and `stop_run_on_fail` ended the run with an outer round left. §3 already lets any member end a round for an earlier member (`ends_round`); when that happens in the inner loop's last round, the finding needs a stage the inner loop's rounds could no longer reach.

- **An inner loop the outer loop names in `stop_run_on_fail:`, out of rounds on a round a member ended with `ends_round`, does not end the run while the outer loop has rounds:** the outer round ends (`cycle.round.ended_early`, reason `inner_loop_ended_for_earlier`) and the outer loop goes round, its inner loop from round 1. In the outer loop's last round the run ends as before, naming the inner loop.
- **Only the inner loop's last round counts:** a round ended so earlier, followed by a round that failed otherwise, ends the run as before.

## Amendment 2026-11-18 (#2565) — §6: done is only for what this call changed; a try that changed nothing is held to its answers

- **The shared answer rules say:** "Answer done only for what you changed in this call. If the finding needs no change because your output is already right, answer wrong, and say why. If someone else must change something, answer not mine, and say who." (`stage_answer_forms`, `scripts/lib/stage-prompt.sh`.)
- **A try that changed nothing is held to what it answered** (ADR-054 §6a, amended 2026-11-18): its `wrong` and `not mine` answers to its own check's findings are handed on to the stage that reads its handoff output and the round ends (§3); one to another stage's finding goes back to that judge as before; a `done` is a finding back to it. Only a try that failed and may be tried again is held so: a halting outcome halts.

## Amendment 2026-11-18 (#2565) — §6: build answers each design step as it answers each finding

- **§6: a design step is answered like a finding, in two words of its own:** `step N: done — QUOTE: <file> | <a line this change added>` (it did the step, and the quote is the line that does it) or `step N: not needed — <why>`. `done` means the same as for a finding: something this change added does it. A step with no answer stays open: build's try is unusable, and the step is shown to it again as a finding (ADR-071, amended 2026-11-18).
- **An answer line starts a reply unit of its own** (`scripts/lib/reply-units.sh`), so a step answer straight after build's prose is read whole.

## Amendment 2026-11-19 (#2567) — §6: each kind of answer is read by a check, named with its test

A claim no check reads is a claim a stage can make to get past its own round: on #1764 run 44417314654 build's "not needed" answers to design steps were read by nothing, and the issue's main change was never made. Each kind of answer a stage gives is read by a check; the list below is every kind there is today, each with its check and the test that holds it. A new kind of answer names its check and its test here, in the same PR.

- **build's done to a design step:** build's `check` call (ADR-072 §3) — `plugins/agent/build/tests/build-step-answers-test.sh` BS1.
- **build's not needed to a design step:** build's `check` call (ADR-072 §3, amended 2026-11-19) — `build-step-answers-test.sh` BS5, BS15.
- **any stage's done, wrong or not mine to a finding:** the judge that raised the finding, when it runs again (§6) — `tests/unit/finding-answers-test.sh`.
- **build's "the test is wrong":** test-author, as a finding (§6, #2441) — `tests/unit/build-test-is-wrong-test.sh`.
- **design's [done] SPEC:** design's check reads its evidence in the code from before the change (ADR-069 §2) — `tests/unit/design-status-check-test.sh`.

## Amendment 2026-11-20 (#2569) — §8: design refines its newest try, and "its last good output" is the newest passing one

On #1764 run 44530053809 design's prompt showed the last design that passed in full under "YOUR LATEST DESIGN", and the working copy — the newer try, rejected — only as a path. Try i1a12 re-added, word for word, a step the working copy had removed. The same run's Previous work named, as design's last good output, iter-3-attempt-1 (11-17) over iter-2-attempt-9 (11-19): it was chosen by iteration number.

- **After a rejected try, the working copy is the design design refines** (§10's working copy). It is shown in full under "YOUR LATEST DESIGN". The last design that passed (`design.md`, or the `design` input) follows under its own heading, as reference only: "The last design that passed — for reference; do not copy back what your newest try removed". After a try that passed nothing changes: the working copy is a copy of `design.md`, shown once, with no reference section (`plugins/agent/design/lib/run.sh`).
- **A try that was not finished is no design to refine** (#2569 review). The working copy is not finished when it has no acceptance block, when design's last result says the call that wrote it was cut off (the reason ends " — its call was cut off before it ended", written by design on a call that did not end normally), or when that result is a pass (no check judged this copy: the stage stopped during its call). Then the last design that passed is YOUR LATEST DESIGN, the working copy starts as it again, and the unfinished try follows under "Your last try, not finished — for reference". With no design that passed, the unfinished try is YOUR LATEST DESIGN, to be finished. The opening sentence says what is shown: it names the last design that passed only when one is shown, and says "No design has passed yet." when none has (`_design_draft_unfinished`, `plugins/agent/design/lib/run.sh`).
- **"Its last good output" is the newest passing output.** Of the archived attempts that produced their output (`scripts/lib/stage-previous-work.sh` `_sp_last_good_attempt`), the newest is the one whose record the attempt archive wrote last (`attempt.json` `generated_at`), then the highest iteration and attempt number. An earlier run's round 3 is older than this run's round 2, and a file's modification time is when it was put back, not when it was written.

## Amendment 2026-11-20 (#2575) — §8: a stage's own notes and output written for an earlier version of what it is asked are marked; §6: build's every change traces to a step or a failing test

On #1764 run 44782866204 build was given its own notes from an earlier run, headed "Status: COMPLETE" and "State of key files (all correct)". They described the architecture the current design reverses. Build spent its round-1 try reconciling the two — 42 tool calls, no edits, a timeout — and later copied an earlier run's wrong answer to a lens finding.

- **What a stage is asked** is what defines the ask in the `ask` outputs (ADR-071) of the other stages it takes. A document counts by its ```acceptance block, and only the producing stage's own one (`required: true`; design's `design`, not its working copy `design_draft`). A JSON file counts whole, less a top-level `"title"` (design's `work_steps`, design-steps.json — the steps; intake's `requirements`). Results and summaries, prose (the design's reasoning, intake's `intake_goal` and `scope_manifest`) and drafts do not count: they change when the ask does not. A stage whose `takes:` names no `ask` topic is asked nothing here, and keeps no record.
- **Decided by fingerprint, from the engine's own record.** Each prompt built for a stage records, beside its notes (`<notes>.asked`, saved and restored with them), five fingerprints: what the notes were written for (W), what the stage's output was written for (L), what it was given at this prompt (S), and its notes (N) and its result (O) as they were then. Notes that changed since were written for S, and so was a result that changed: L moves only when the stage's result file is rewritten, so a retry that wrote nothing, or a second prompt built for the same stage, keeps the mark. Fingerprints are taken by `scripts/lib/digest.sh`: FNV-1a over the bytes by the shell for a file or text up to 16 KB (no program), one `cksum` for a larger one; NULs count, except one as the very last byte. No copy of an input or the notes is kept, and no file time is read (a restored file's time is when it was put back). The record is rewritten only when it changes, in one write ending in an end line; a record without its end line (a write cut short) is read as none — the notes then marked, the safe side. It is not renamed into place: a rename is one program more on every dispatch that changes it (ADR-065 §5) (`scripts/lib/stage-notes-version.sh`).
- **Marked, not left out.** Notes written for an earlier version are shown under "Your notes so far, written for an earlier version of <input> — check them against the current one"; the stage's own output from before is headed "Your output below was written for an earlier version of <input> — check it against the current one." <input> names the outputs that changed, by id (`design`, `work_steps`, `requirements`). Notes with no record (from before this rule) are marked with every input; an output with no record is not marked (nothing says what it was written for). Why marked: the notes still say what was done on the branch, which a rerun needs, and a design rewritten to the same effect would otherwise cost the stage all of them; the mark says which input to check them against, and the line above the notes already says a list or result elsewhere wins. This applies to every stage.
- **§6, build:** every change traces to a design step or to a failing test; a change that traces to neither is not made, and one the branch already has is taken out. When a step is gone from the design, build undoes what it built for it, unless the current design's steps now name it (`plugins/agent/build/lib/prompt.sh`). The acceptance check reports such a change when no test checks it (ADR-036, amended 2026-11-20).

## Amendment 2026-11-20 (#2574) — §5 §6: a finding has a stable id; an answer names it and carries its text

§5 gave a finding its identity from where it lives — the stage's result, item n — and §7 said numbers only had to be unique within one list. Answers named a finding that way ("design finding 2"), and the list changes between tries, so on #1764 run 44782866204 an answer could attach to a different finding.

- **§5: every finding has an id in the scheme requirements and SPECs use** (`scripts/lib/item-ids.sh`, ADR-069 §1): its stage's prefix and a code of its own — `<prefix>FND`, or, for a stage with several checks of its own, a tag each takes (a lens: its whole name, letters and digits in upper case, `RLSRE`, `RLCORRECTNESS`) — a dash and a number. The same finding, the same text, keeps its id however the list changes; a new one takes the number after the highest its code has had, removed ones counted, so a removed id never comes back. What each code has given is kept beside the stage's outputs (`finding-ids-<code>.json`, written whole with `atomic_write`; a record that cannot be written leaves `stage.finding_ids.write_failed`), and the numbering is done in the jq the writer already runs (`zb_fids`). The writers: `stage_findings_json` (design's result, test-author's result, build's tests and secrets findings), `stage_findings_route` and `stage_findings_route_each` (issue-acceptance, the test tool: ids given once over the distinct texts, then fanned out, so a finding sent to several topics has one id in every output and in the stage's own list), `stage_findings_add` (test-author's design output, the no-change handoff's output, build's carried finding), `stage_handoff_unchanged` (a finding sent back), `_build_write_build_summary` (build's summary) and a lens's routed results (`_review_lens_run_inner`). `n` stays, as the finding's place in its list.
- **§5: later stages see each finding by its id**: `- <id> (opened by <stage>): …`. A finding written before ids is shown as before, `- <label> finding <n> (opened by <stage>): …`.
- **§6: a stage answers a finding by its id**, `ANSWER <id>: done | wrong | not mine — …` (the engine's answer forms say so); the form before ids is still read during the change-over (`zb_answers_collect_v`, `zb_answer_kind_v`, `zb_answers_finish`). A stage keeps, beside its answers, the text of each finding it answered as it was shown it (`data.answer_findings`, `zb_answers_findings_json_v`): the finding travels with the answer, so the check it goes back to is held to that finding (ADR-072 §5, amended 2026-11-20), and an answer whose finding is gone is attached to no other.

## Amendment 2026-11-21 (#2579) — §6: a design step names the SPECs it serves

A step is a summary of part of the SPECs; on #1764 run 44863026881 the "only" of DSCLA-23 was not in the step that served it, and the step's check, shown only the step, passed a fallback that broke it.

- **§6: each design step names the SPECs it serves**, by their ids, after ` | serves:` on its line (`- <what to do> | areas: <areas> | serves: DSLOOP-1, DSLOOP-2`): a trailing `[tag]` is taken off, a word that is no id is set aside, and an id named twice counts once. One parser reads a step's parts (`zb_design_step_split`, `scripts/lib/design-steps.sh`); its areas stop where ` | serves:` starts.
- **§6: design's check refuses a step that names no SPEC** (`STEP_NO_SPEC`), and one that names an id the acceptance block has no SPEC for (`STEP_UNKNOWN_SPEC`).
- **§6: design-steps.json carries each step's `serves`, and `specs`: the text of each served SPEC with its parts**, as a model is shown a SPEC (`acceptance_spec_render_v`). Build's step check is shown them (ADR-072 §3, amended 2026-11-21).

## Amendment 2026-11-21 (#2582) — §6: an accepted answer stands; a step points to its SPECs

On #1764 run 44910536811 try 1's step check refused only step 7; try 2 answered only step 7, and steps 1–6 and 8 were marked "no answer" before their kept verdicts were read — a try lost. Step 7 had also rewritten DSADR-7's four Enforced-by entries in its own words, folding §1(b) into §1(a); build followed the step, and its step check refused it against the SPEC.

- **§6: an accepted answer stands.** A step's answer the check accepted is kept with its verdict (ADR-072 §4, amended 2026-11-21). On a later try, a step build does not answer keeps that answer: its kept verdict stands while the step's words, the SPECs it serves and the code its answer points to are unchanged. When only that code changed — the quoted file elsewhere, or for a not needed the code in the step's areas — and a done's quoted line is still a line this change added in the step's areas, the answer is judged again in the same call, as if build had given it. When its line is gone, its file is out of the step's areas, or the step or a SPEC it serves changed, it no longer stands, and the finding says why: "step N's earlier answer no longer stands: <why> — answer it again". A step refused before and not answered now has no answer. Build's prompt says what the code does: "A step accepted on an earlier try stands: you need not answer it again. Answer it again only when you change what it answered. When the code its line is in changes, it is judged again on that answer (a not needed: the code in its areas); when its line is gone, or the step or a SPEC it serves changes, you are asked to answer it again." (`_build_steps_kept_answers`, `plugins/agent/build/lib/steps-quote.sh`; `_build_steps_judge`).
- **§6: answers to findings have no such gap.** A finding whose answer its check accepted is not reported again, so it is not shown and needs no answer; a check's kept pass is used whatever a later try answers (`judge_kept_get_all_v`, pass-words) — `tests/unit/checks-held-to-findings-test.sh` H8. An answer given in a try the check has not yet judged lives in that try's result, as every stage output does (§8): a later try that drops it leaves the finding open, named as not answered and shown again — it was not yet accepted — `tests/unit/finding-answers-test.sh` B1.
- **§6: a step says where and how, and points to its SPECs; it does not restate them.** Design's prompt: "A step says where and how; it points to the SPECs it serves with serves: and does not restate what they require — a step that rewords one can lose part of it." (`plugins/agent/design/lib/run.sh`).

## Amendment 2026-11-22 (#2586) — §6: a "wrong" does not close a finding the final judge still holds; §8: every stage's failed checks are open items

On #2532 run 45017980554 test-author, which owns the guard test, answered build's finding "wrong — theoretical concern", while issue-acceptance still found the requirement behind it unmet.

- **§6: when a stage answers one of issue-acceptance's findings "wrong" and issue-acceptance still finds the requirement unmet, the round does not pass.** A wrong to another stage's finding (build's, a lens's) is not covered here; with §5 (#2586) issue-acceptance's own verdict on the requirement now stands, which is what ends the round. A plain wrong to an issue-acceptance finding — one that quotes no line showing the requirement met — does not dispute it: the refusal stands and the finding goes on again, carrying the answer, to the stages its mark names (a `[fix-code]` or unmarked one reaches test-author, which owns a test file). The owner fixes it, or answers wrong quoting the line that shows it met, which has the requirement judged again (ADR-072 §5, amended the same day). An issue-acceptance item that a finding names is not held to its kept pass (same amendment).
- **§8: the open items include every stage's failed checks** (ADR-064 §4, amended the same day): build's unfinished steps and the failing tests among them.

## Amendment 2026-11-23 (#2590) — §5: an engine note never changes a finding's id

A finding's id is made from its text up to ` ¶ `. The engine's own notes on a finding go after it: issue-acceptance's "answered before: … a wrong that quotes no line does not close it" (#2586) is one. A note therefore never makes the same finding look new to the stage that owns it. The note travels in the text after a separator rather than in a field of its own: every reader already shows `.text`, and ` ¶ ` does not occur in written findings. A finding a model wrote with ` ¶ ` in it would take its id from the words before it.

## Amendment 2026-11-23 (#2599) — §6: a "not mine" reaches the stage it names, every try

A "not mine" answer is handed on every try, whether the answering stage passed or failed and whether it changed anything. One reader decides where it goes (`zb_not_mine_target_v`), ignoring case:
1. a stage it names ("design must …", "the code must change", "test-author must") wins;
2. otherwise a file it names: one in the test folders is test's, any other path is code's;
3. otherwise a stage named in passing.

Build's go to test-author (`build-tests-result.json`) or design (`build-design-result.json`, new). Test-author's go to build (`test-author-code-result.json`, new, topic code-findings) or design. Each keeps the finding's id and its text, beside the answer.

- **Nothing is handed back.** A finding one of them handed to the other (its id carries the giver's code) and answered "not mine" goes to design, which can settle whose it is.
- **A stage's own check's findings are unchanged:** the old path still handles them.

Until now, `stage-handoff.sh` handed on a "not mine" only from a try that failed and changed nothing, and sent one about another stage's finding back to its judge. A lens reviews fresh (#2584), so that judge never saw the answer. On #2532 run 45231040380, four findings went back to the same owner round after round.

## Amendment 2026-11-25 (#2611) — §3: a stage requires earlier stages to have passed; a map member that does not finish only does not pass; §6: an answer carries to the next try

- **§3: `requires:`.** A top-level flow stage may declare `requires: [<stage>, …]`. The engine runs it only when each named stage is complete with a pass (`scripts/lib/stage-requires.sh`, asked before each top-level unit); otherwise the run ends, failed, naming them — as soon as a unit it requires has run and not passed, not after every unit between (`stage_requires_ahead`). A name that is not a stage the flow runs before it, a value that is not a flow list, or a `requires:` on a stage inside a loop or group refuses the template. The linear path asks the same gate. `requires: all` is every stage and loop the flow runs before it. A stage whose requires were met is told so (`ZBUILD_STAGE_REQUIRES_MET=yes`); one that requires nothing is not. `simple.yaml` and `deployed.yaml` give `pr` `requires: all`: no PR when any stage or loop before it did not pass, not only the lenses. *(Amended 2026-11-26, #2614: a stage marked not blocking is not part of `all` — below.)*
- **§3: a map group in a loop follows `stop_run_on_fail:` like any member.** An element that failed or did not finish sends the loop round; only one whose result halts the run stops it (ADR-040, amended 2026-11-25). A member that stopped the run with its own reason is named with it (`stage_stopped:<member>:<reason>`); only a member out of its tries is `out_of_tries:`.
- **§6: an answer carries to the next try.** Amends the 2026-11-21 (#2582) sentence "a later try that drops it leaves the finding open, named as not answered". A finding a try was shown and did not answer keeps the answer the stage's own latest result gave it, when that result was written in this run (after the run-start marker) and the finding is the one it answered, word for word (`data.answer_findings`). It is still not accepted until a check judges it; it is not reported as not answered. Each stage is still asked to answer every finding again (#2501). On #2533 run 45644128060 design try 1 answered BUFND-14 "wrong", and try 2 reported it "not answered".

## Amendment 2026-11-26 (#2614) — §3: a stage that does not block is not required by `requires: all`

- **§3: `requires: all` leaves out a stage marked not blocking** (`blocking: false`). Such a stage's failure does not end the run (ADR-013), and it holds back no later stage either: hydrate's failed restore starts the run fresh, and `pr` can still run. This supersedes the #2611 sentence that a non-blocking stage that failed, hydrate's restore among them, keeps `pr` from running. A stage named by hand in `requires: [...]` is still required, whatever its `blocking:`.
- `simple.yaml`'s `pr` therefore requires `intake issue-check delivery_loop` (ADR-074), and `deployed.yaml`'s `intake delivery_loop`.

## Enforced by

- §3 amendment 2026-11-26 (#2614: a stage that does not block is not part of requires: all) → `tests/unit/stage-requires-test.sh` RQ10, RQ3

- §3 §6 amendment 2026-11-25 (#2611: requires:; a map member follows stop_run_on_fail; an answer carries) → `tests/unit/stage-requires-test.sh` RQ1–RQ8; `tests/integration/cycle-map-member-test.sh` M3, M5, M6; `tests/unit/finding-answers-test.sh` B6

- §6 amendment 2026-11-23 (#2599: a "not mine" reaches the stage it names, every try) → `tests/unit/not-mine-handoff-test.sh` N3–N13

- §5 amendment 2026-11-23 (#2590: an engine note never changes a finding's id) → `tests/unit/issue-acceptance-per-item-test.sh` PI18

- §6 §8 amendment 2026-11-22 (#2586: a plain wrong; every stage's failed checks) → `tests/unit/issue-acceptance-per-item-test.sh` PI15, PI16, PI17 (a quote as models format it); `tests/unit/run-stop-names-blocker-test.sh` B1, B2, B7 (a finding in two of a stage's files is one item)

- §6 amendment 2026-11-21 (#2582: an accepted answer stands; a step points to its SPECs) → `plugins/agent/build/tests/build-step-stands-test.sh` SA1 (an accepted step not answered stands; the judge is not asked), SA2 (the quoted file changed elsewhere: judged again in the same call), SA2b (its line is gone), SA3, SA4 (the step's words, or a served SPEC changed: answer it again, saying why), SA5 (refused before: no answer), SA6 (build's prompt); answers to findings: `tests/unit/checks-held-to-findings-test.sh` H8 (a kept pass used with no answer), `tests/unit/finding-answers-test.sh` B1 (a dropped answer leaves the finding open); `tests/unit/design-steps-serve-specs-test.sh` SV8 (design's prompt)

- §6 amendment 2026-11-21 (#2579: a step names the SPECs it serves) → `tests/unit/design-steps-serve-specs-test.sh` SV1 (no SPEC: refused), SV2 (an unknown id: refused), SV3 (named: passes; the areas hold no SPEC), SV4 (design-steps.json holds serves and each served SPEC's text), SV5 (design's prompt asks for them), SV6 (tags, prose, repeats; the caller's IFS), SV7 (a record separator in a step's words)
- §8 §6 amendment 2026-11-20 (#2575: old notes are marked; build's changes trace to an ask) → `tests/unit/notes-earlier-version-test.sh` V1 (notes written for the design as it is: no mark), V2 (written before the design changed: marked, naming only what changed), V3 (the stage's own output marked), V4 (notes and a result written after the change: no mark), V5 (no record: marked), V6 (every stage: design's notes marked when the requirements change, not its own output), V7 (a stage asked nothing), V8 (the output mark stays on every prompt until a new result), V9 (prose, draft and issue text mark nothing; steps or SPECs do), V10 (fingerprints, not copies; nothing left beside it), V11 (a byte after a NUL counts), V12 (a 100 KB input is fingerprinted whole); `tests/unit/change-traces-to-ask-test.sh` A1 (build's prompt)
- §5 amendment 2026-11-20 (#2574 review: every writer keeps the record; one id over every topic; written whole) → `tests/unit/finding-ids-writers-test.sh` W1 (build's summary keeps its record), W2 (one id in every topic's output, issue-acceptance and the test tool), W5 (atomic_write; an event when it fails), W6 (stage_findings_add never reads stdin)
- §5 §6 amendment 2026-11-20 (#2574: stable finding ids; answers name them and carry their text) → `tests/unit/finding-ids-test.sh` I1 (stable, never reused, removed ones counted), I2 (one id in every output; add numbers from the same record), I3 (shown by its id; told to answer by it), I4 (ANSWER <id> read; the old form still read), I5 (the text travels with the answer), I6, I7; `tests/unit/finding-answers-test.sh` C2, C3 (a lens finding shown by its id; an old-form answer still reaches it)

- §8 amendment 2026-11-20 (#2569: design refines its newest try; the last good output is the newest) → `tests/unit/design-refines-newest-try-test.sh` N1 (after a rejected try YOUR LATEST DESIGN is the working copy, in full), N2 (the last passing design under its own reference heading), N3 (after a try that passed, unchanged), N4 (the newest passing attempt by its recorded time, from the attempt archive's own records), N5 (a try cut off at its time limit: the last design that passed is refined, the try shown as unfinished, the working copy reset), N6 (a working copy with no acceptance block), N7 (the opening sentence says what is shown), N8 (a working copy no result judged)

- §6 amendment 2026-11-19 (#2567: every claim is read by a check) → build done and not needed: `plugins/agent/build/tests/build-step-answers-test.sh` BS1, BS5, BS15; answers to a finding back to its judge: `tests/unit/finding-answers-test.sh`; build's "the test is wrong": `tests/unit/build-test-is-wrong-test.sh`; design [done]: `tests/unit/design-status-check-test.sh`

- §6 amendment 2026-11-18 (#2565: done only for what this call changed; a try that changed nothing is held to its answers) → `tests/unit/no-change-handoff-test.sh` H8 (the rule's three sentences), H2–H4 (each answer of a try that changed nothing)
- §6 amendment 2026-11-18 (#2565: build answers each design step) → `plugins/agent/build/tests/build-step-answers-test.sh` BS1 (an answer right after prose is read), BS2 (a step with no answer stays open), BS5 (not needed needs its why)

- §6 amendment 2026-11-16 (#2554: the before-run says only what it saw) → `tests/unit/test-author-before-run-test.sh` B4, B12

- §3 amendment 2026-11-14 (#2543: an inner loop out of rounds on an ends_round round goes round instead of ending the run) → `tests/integration/stop-run-on-fail-test.sh` R9–R11

- §6 amendment 2026-11-09 (#2506: test-author runs only a failing test of its own; build's "the test is wrong" wins; a failed stage shows what failed when it ran) → `tests/unit/test-author-checks-own-output-test.sh` A8, A15; `tests/unit/test-author-before-run-test.sh` B1; `tests/unit/build-test-is-wrong-test.sh` W7, W8; `tests/unit/build-prompt-loop-complete-rule-test.sh` T1; `tests/unit/stage-boundaries-test.sh` SPEC-2

- §8 amendment 2026-11-09 (#2508: a failed run's report shows the questions design could not settle) → `tests/unit/unclear-questions-shown-test.sh` Q3 (the end-of-run banner and the completion comment), Q5

- §6 amendment 2026-11-08 (#2503: test-author runs a failing test before changing it; build says a test is wrong on a check) → `tests/unit/test-author-checks-own-output-test.sh` A14; `tests/unit/build-test-is-wrong-test.sh` W6
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
- Amendment 2026-11-12 §6 (#2527: build's test answers read by the one reader) → `tests/unit/build-test-is-wrong-test.sh` W9
