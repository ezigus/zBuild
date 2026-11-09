# ADR-072 — A judge reads the code itself, quotes what it complains about, and keeps its answer while nothing changes

**Status:** Accepted (2026-11-03); amended 2026-11-09 (#2506, §3: a lens names no line; its finding is shown with its quote); amended 2026-11-09 (#2505, §3: a file name in formatting marks is the file); amended 2026-11-08 (#2495, §3 §4: the scope is not judged — #2491's scope lines are removed); amended 2026-11-08 (#2491, §3 §4: each scope entry gets a line of its own, ok or outside, kept per entry); amended 2026-11-07 (#2487, §3: an escaped quote mark is the mark itself); amended 2026-11-04 (#2466, §2 §4: the old-code copy and every kept answer leave events); amended 2026-11-04 (#2467, §3: the checks answer one line per part of a SPEC); amended 2026-11-04 (#2470, §3 §4: one line per SPEC that is fine and one per failing part; design's check keeps its answer per SPEC, is given the draft by its path, and judges only the SPECs that changed); amended 2026-11-05 (#2472, §3 §4: quotes ignore formatting; a kept answer does not depend on the file its items come from; a bad line costs only its own item); amended 2026-11-05 (#2474, §3: every reply line is read with its formatting aside)
**Issue:** #2464 (runs 41643063636 and 41679237388 on #1805)
**Amends:** ADR-068 §6 §7 (answers are kept in a stage's result; a check keeps a verdict whose inputs have not changed), ADR-017 §11 (`tools: read`), ADR-069 §2 (a `[done]` claim is read in the code from before the change, by file), ADR-067 §8 (a judging call can read and search files, and nothing else)
**Related:** ADR-060 §6 (one re-ask), ADR-054 §7 (teardown frees run resources), ADR-066 (every ADR statement has a test)

## Context

A judging call is a model call whose answer the engine acts on: design's coverage check, test-author's assertion check, issue-acceptance, and the review lenses. Two runs of #1805 on 2026-11-03 ended on judges' answers, and in each case the engine took the answer as fact:

- **The same files got opposite answers.** test-author's check called BNDY-1 "corresponds" in rounds 1 and 2, and "partial" in round 3, with the test files unchanged. That flip ended run 41643063636.
- **An empty answer became two findings.** Design's coverage judge wrote `VERDICT: covered`, then `omitted` and `(none)` where its lists were empty. The parser dropped only the exact word `none`, so each blank became a finding. Design spent two of its three tries in run 41679237388 guessing what they meant.
- **The judge ruled on ten lines.** It called SKIP-1's `[done]` claim wrong from ten lines around the evidence. The `continue` that proves the claim was just past them.
- **The judge read the wrong code.** It judged "the code already does this" on the branch's own version (`_dcov_done_evidence` read the working copy). The claim is about the code from before the change.
- **The judges had every tool and used none.** Every judging call but intake's ran with every tool and write access to the repository. Their prompts told them to judge what was pasted in, and they made no tool call.

## Decision

1. **A judging call reads the code itself, and can change nothing.**
   - It gets Read, Grep and Glob, and no MCP server: the router passes `--strict-mcp-config --tools "Read,Grep,Glob"`.
   - A plugin whose every call judges declares `config.router.tools: read`: issue-acceptance, review-lens and security-lens.
   - The design coverage check and test-author's assertion check run inside stages that need full tools for their own call, so they ask for read-only tools for their call only (`ZBUILD_ROUTE_TOOLS=read`).
   - `tools: none` wins over both. intake and monitor declare it: everything they judge is in their prompt.
   - The rules a judging call is given (`--fresh`) say it can open and search files and change none, and that it should open whatever it needs.
2. **The code is given by file, never by snippet.**
   - A judge is pointed at a file and a piece of its text, and opens the file itself. No judge is given a window of lines.
   - The code from before the change is a read-only copy of the base commit (the merge-base with the default branch), at `<run state>/base-code`:
     - It is made with `git worktree add --detach` the first time a judge asks for it (`judge_base_dir_v`, `scripts/lib/judge.sh`), and shared for the rest of the run.
     - It sits outside the repository, on no branch, so it never appears in `git status` and is never committed.
     - A new base commit gets a new copy.
     - teardown removes it, and git's record of it, on every exit path (ADR-054 §7).
   - Design's coverage check reads a `[done]` claim's code in that copy.
3. **One line per item, and every complaint quoted.**
   - **Design's coverage check** answers one line per requirement (`covered`, or `uncovered`) and one per SPEC (`ok`, `outside`, or `done_wrong`). `done_wrong` is only for a SPEC marked `[done]`. *Amended 2026-11-08 (#2495):* the scope is not judged, and has no line (ADR-070 §4); #2491's `SCOPE:` lines are removed.
   - **test-author's assertion check** answers one line per SPEC.
   - **issue-acceptance** answers `MET:`, `UNMET:` or `UNSURE:` for each listed requirement.
   - **A review lens** gives each finding a `quote` field.
   - A complaint quotes the text it is about, as `| QUOTE:` at the end of its line:
     - `"<words>"` must be in the item's own words (and, for issue-acceptance, the issue's);
     - `<file>:"<text>"` must be in that file, in the repository or in the old-code copy. A lens's quote may also be a line the change removed.
     - Spacing does not count (`judge_quote_check_v`).
   - A missing line, a word that is not that item's kind, or a quote that is not there makes the answer unusable. It is asked again once, saying what was wrong (ADR-060 §6). If it is still wrong, the item is not judged: the check ends `unusable`. A bad answer never becomes a finding and never becomes a pass.
   - A line that names nothing (`none`, `omitted`, `(none)`) is not an item.
4. **A verdict is kept while what it judged is unchanged.**
   - Each check keeps its answer in its own output in the artifacts folder, which hydrate carries into the next run: `design-judged.json`, `test-author-judged.json` (one entry per SPEC), `issue-acceptance-judged.json`, and `lens-<id>-judged.json`.
   - Each answer is kept with:
     - a fingerprint of the engine's commit, what the judge was shown of the item, and the answers to its earlier findings (§5);
     - the content hash of every file it depends on: the files the call opened (from the call's own step stream, `ZBUILD_ROUTER_OPENED_FILE`), the files its quotes name, and, for test-author's check, the SPEC's test files. A directory the call searched counts by the commit's tree of it, so a commit that changes a file in it is judged again; one outside any repository is never known unchanged.
   - When all of these are unchanged, the kept answer is used and no call is made (event `judge.kept`). This holds for fails as much as for passes: the same input gives the same answer.
   - Only what changed is judged again. test-author's check sends only the changed SPECs to its judge.
   - The judge itself still starts fresh (ADR-067 §8): it is never shown its earlier verdict. It is simply not asked the same question twice.
5. **A disputed verdict is judged again.**
   - A stage that answers a finding with `ANSWER <stage> finding <n>: nothing to do — <why>` keeps that answer in its result (`data.answers`). This applies to build and design, as it already did to test-author.
   - Design may now answer its own check's findings: its reply's `ANSWER design finding <n>: …` lines reach the check.
   - A "nothing to do" answer to one of a check's findings is part of that check's fingerprint. The item is therefore judged again, with the answer shown under ANSWERS TO YOUR EARLIER FINDINGS, and the new verdict is kept in turn.
   - For test-author's check, only the SPEC whose finding was answered is judged again.

## Consequences

- A judge cannot flip on unchanged input. A wrong first verdict stays wrong until the work changes or a stage disputes it, and a dispute is the way out.
- `omitted`, `(none)` and other filler can no longer become findings, and a finding without real text behind it is refused.
- Judges spend turns reading code, so they cost more time per call; calls whose answers are kept cost none.
- A judge cannot edit the work it is judging.

## Implementation Notes

- **`scripts/lib/judge.sh`**:
  - old-code copy: `judge_base_dir_v`, `judge_base_release`;
  - quotes: `judge_quote_check_v`, `judge_quote_path_v`;
  - answers: `zb_answers_collect_v`, `judge_answers_to`, `judge_disputes_block`;
  - kept verdicts: `judge_engine_v`, `judge_fp_v`, `judge_kept_get_v`, `judge_kept_put`, `judge_opened_v`.
- **The router and the rules** (`core/router/route.sh`, `scripts/lib/stage-limits.sh`, `scripts/lib/stage-prompt.sh`): `_route_judge_tools` picks the read-only tools, `_route_stream_opened` lists the files a call opened, and `_stage_block_rules_pair_v` writes the read-only rules.
- **The judges and the stages that answer them**:
  - design: `plugins/agent/design/lib/coverage.sh` (`_dcov_parse`, `_design_coverage`), with `plugin.sh` collecting design's answers;
  - test-author: `plugins/agent/test-author/lib/correspondence.sh` (`_sc_disputes`, `_ta_correspondence`);
  - issue-acceptance: `plugins/agent/issue-acceptance/plugin.sh` (`_ia_parse`, `_ia_finish`);
  - review-lens: `plugins/agent/review-lens/plugin.sh` (`_rl_quote_problem_v`) and `lib/charters.sh`;
  - build: `plugins/agent/build/lib/summary.sh` (`_build_answers_json`);
  - teardown: `plugins/tool/teardown/plugin.sh`.

## Amendment 2026-11-04 (#2466) — §2 §4: the old-code copy and every kept answer leave events

On #1805 run 41757933766, two things could only be inferred, never read off the run: whether the old-code copy was removed, and which SPECs reused a kept verdict. `judge.kept` fired only when every item of a check was kept.

- **§2:** making the copy emits `judge.base.created` (`base`, `path`). Not making it emits `judge.base.failed` (`reason`: `no_state_dir`, `no_base_commit` or `worktree_add_failed`). Removing it emits `judge.base.released` (`path`, and `by`: `teardown`, or `new_base` when a new base commit replaces it). With nothing to remove, nothing is emitted.
- **§4:** one event per item. `judge.kept.saved` when a verdict is kept. `judge.kept.used` when a kept verdict is used and that item is not sent to the judge. `judge.kept.stale` when a kept verdict exists but cannot be used, with `why`: `fingerprint` (what was judged changed), `disputed` (a stage answered one of its findings) or `file` (a file it depended on changed). Each carries `check` (`design`, `test-author`, `issue-acceptance`, `lens-<id>`) and `item` (the SPEC id, or `coverage`, `issue`, `lens`). `judge.kept` is gone. Each event is declared by the plugins that emit it.

## Amendment 2026-11-04 (#2467) — §3: the checks answer one line per part of a SPEC

design's coverage check and test-author's assertion check answer one line for every part of every SPEC (ADR-073 §5 §6), each complaint quoted from that part. A part with no line makes the answer unusable, asked again once. design's check adds the part verdicts `untestable`, `how`, `contradicts` and `duplicate`, and the SPEC verdict `needs_cleanup`; test-author's check answers `ok`, `missing` or `wrong` per part, a line for the test's sections, and `untestable` for a SPEC no test can prove, which ends the run.

## Amendment 2026-11-04 (#2470) — §3 §4: answers per SPEC, kept per SPEC

On #1805 run 41845438073 one unchanged part was `ok` in try 2 and `how` in try 3: design's check kept one answer for the whole design, so a one-line edit to one SPEC sent every SPEC back to the judge. The judge also opened the old design.md while judging the draft.

- **§3:** design's coverage check and test-author's assertion check answer one line for a SPEC that is fine (`<id>: ok`) and one for each thing wrong. A part is named by its word and a quote of its own words (ADR-073 amendment, #2470). A SPEC with no line makes the answer unusable, asked again once naming it. Requirement lines and `SCOPE:` lines are asked only when requirement coverage is asked (below).
- **§4: design's check keeps its answer per SPEC.** `design-judged.json` holds one entry per SPEC and one, `requirements`, for requirement coverage and the scope.
  - A SPEC's fingerprint is the engine's commit, the SPEC as shown (its first line and parts), its `[done]` evidence, the base commit and the answers to its own findings.
  - The `requirements` fingerprint is the engine's commit, the requirements, every SPEC as shown, the scope, every `[done]` evidence, the base commit and the answers to a requirement's or scope entry's finding. So requirement coverage is asked again whenever any SPEC changes.
  - Only what is not kept is judged. The judge is given the draft by its path and told not to open design.md, an earlier design. It is shown in full only the SPECs it judges; when requirement coverage is asked, the other SPECs are shown by their first line, for what they cover.
  - A "nothing to do" answer to a finding disputes the item that finding is about, found by the finding's first word (a SPEC id, a requirement id, or `SCOPE`): only that item is judged again. One that names nothing known disputes every item.
  - The verdict is every item's answer together: the kept ones and the new ones.
  - Events (§4, #2466) carry `item` = the SPEC id or `requirements`; the single `coverage` item is gone.
  - `judge_kept_get_all_v` and `judge_kept_put_all` (`scripts/lib/judge.sh`) read and write every item of a check in one pass.

## Amendment 2026-11-05 (#2472) — §3 §4: formatting aside, and a judge's good answers are kept

On #1805 run 41951779189 design's check refused a correct quote: the issue wrote `stage *k* is dispatched` and the judge quoted "stage k is dispatched". The whole answer was thrown away, though every SPEC's line in it was good. And each SPEC's kept answer depended on the draft the judge opened, so any edit made every SPEC's answer stale: two SPECs that never changed were judged again and got new complaints.

- **§3: formatting is not the judge's to get right.** A quote is compared with the markdown marks `*`, `_` and backticks left out on both sides, as spacing already is (`_judge_holds`).
- **§3: a bad line costs only its own item.** design's check reads its answer per item (each SPEC, and `requirements`). An item whose lines are good is taken at once. The re-ask names only the items whose lines are not ("Answer again only for: …"), and only their lines in the second reply count. If they are still bad the check ends `unusable`, as before, but every item taken is kept (§4), so the next try asks only for what is missing. test-author's check already worked this way.
- **§4: a kept answer does not depend on the file its items come from.** Of the files a call opened, the one the check's own items are read from is left out, since each item's words are in its fingerprint: the draft and `design.md` for design's check, the design for test-author's (`judge_opened_v`). A code file the judge read, a file a quote names, and test-author's SPEC test files still count.

## Amendment 2026-11-05 (#2474) — §3: every reply line is read with its formatting aside

#1805 run 42090130741's judge wrote `**RHYD-1** sections: missing`; test-author's reader allowed bold in some places only, so 12 of 13 lines were read as no line and asked again one by one. The run before broke the same way on italics. Each reader kept its own short list of allowed marks.

- **One shared step reads every line** (`judge_reply_line_v` in `scripts/lib/judge.sh`), used by design's check, test-author's check and issue-acceptance. The line's structure — id, part and word — is read with formatting and spacing aside: bold, italics, code marks, a list bullet or number, a quote or heading mark, a table's borders and cells, runs of spaces. An underscore inside a word stays (`done_wrong`).
- **`WHY:` and `QUOTE:` are the separators,** with or without the `|` before them. What follows each is kept as written, without the marks around it, so a finding keeps its code marks.
- **Where a reply's items start is read the same way** (`zb_reply_join_v`), so a line in bold is not joined to the one before it.

## Amendment 2026-11-06 (#2477) — §4: a kept answer depends on the code its test exercises

A kept answer's files were those the call opened, those its quotes name, and test-author's SPEC test files.
A judge that never opened the code under test kept its verdict through any change to it (verified by
`tests/unit/judge-kept-code-test.sh` C1 before the fix).

- **§4: test-author's check counts the design's WIRING files.** Every SPEC it judges is kept with the hash of
  each file the design's `WIRING:` list names — the code whose revert must break a SPEC — whether or not the
  judge opened it. A `[done]` SPEC is not judged by this check, so its evidence is not counted here.
- **§4: issue-acceptance needs nothing new.** Its fingerprint already holds the change's diff, so any change to
  the change's code, opened or not, is judged again.
- The engine's commit stays in every fingerprint: in another repository it changes only when a new zBuild is
  installed.

## Amendment 2026-11-06 (#2476) — §3: issue-acceptance does not investigate a failing test

On #1805 run 42127743259 both round-2 issue-acceptance calls hit their 600s limit with no answer. Only their
prompt held a failing test of the issue's own (an assertion test-author later removed), and each spent the
whole call working out whether the change had caused it. A timed-out call keeps nothing.

- **A failing test it cannot trace to the DIFF within a few reads is UNSURE.** The prompt says to mark the
  requirement it bears on UNSURE, naming the test and that it could not tell whether the change broke it, and
  not to work out why a test fails: that is the build's job.

## Amendment 2026-11-07 — §5: a stage that reports findings is shown last time's, with every answer, and keeps their grade

A stage that reports findings and runs again is shown its findings from last time, each with every answer a stage
gave it (`judge_last_findings_block_v`), before they are cleared. It is told that a finding it reports again keeps
the grade it gave it, unless it quotes what changed since that makes it worse; that one answered done is checked
against what was done; and that one answered wrong is judged again with the answer. Only `wrong` answers are the
disputes of §5 (ADR-068 §6).

## Amendment 2026-11-07 (#2487) — §3: an escaped quote mark is the mark itself

On #1805 run 42397891946 issue-acceptance quoted two code lines that hold `"`, in the form `<file>:"<text>"`, and wrote each `"` inside as `\"`. The check compared the backslashes with the file and refused both quotes; the stage's answer was thrown away, though both its verdicts were right.

- **A quote is read as written, then with its escapes read.** Inside `"…"`, `\"` is a quote mark and `\\` a backslash. It is checked as written first, since code holds real backslashes (`_judge_holds`).

## Amendment 2026-11-08 (#2491) — §3 §4: each scope entry gets a line of its own

On #1805 run 42439063480 design's first try ($2.26) failed on a line that said nothing was wrong. A scope entry the issue did not ask for got a `SCOPE:` line with no verdict word, so writing the line at all was a failure; the judge wrote one whose reason ended "this entry is consistent with the issue's intent and raises no concern".

- **§3: a scope entry is judged as a SPEC is.** One line for every scope entry it is shown: `SCOPE: <entry>: ok`, or `SCOPE: <entry>: outside | WHY: <what the issue does not ask for, or how it contradicts it>`. Only `outside` is a finding. The entry is named exactly as listed, and that is checked: it is its own quote. A missing line, or a word that is not `ok` or `outside`, makes the answer unusable and is asked again once, as for a SPEC. The old `SCOPE:` line with no word is no line.
- **§4: each entry's answer is kept by itself,** with a fingerprint of the entry, the requirements and any answer to its finding. A changed SPEC does not ask it again; requirement coverage no longer depends on the scope.

## Amendment 2026-11-08 (#2495) — §3 §4: the scope is not judged

The coverage check no longer judges the design's scope (ADR-070 §4 amendment, #2495). This removes the `SCOPE:` line from §3, and its entry kept per scope entry from §4, which #2491 added. A `SCOPE:` line in a reply is ignored. A design that goes beyond the issue is judged by its SPECs' `outside`. The `requirements` item's fingerprint and disputes are as #2491 left them: they do not depend on the scope.

## Amendment 2026-11-09 (#2505) — §3: a file name in formatting marks is the file

On #1805 run 42556446368 issue-acceptance quoted `` `tests/integration/pipeline-resume-test.sh`:"…" ``, with the file name in backticks. The check took the backticks as part of the name and answered "not a file of the repository"; asked again with that reason, the judge wrote the same, and its answer was thrown away.

- **The backticks and `*` marks around a quote's file name are left out** before the file is looked up, as formatting is left out of the text (#2472). A file that is not there is still refused, and named without the marks.

## Amendment 2026-11-09 (#2506) — §3: a lens names no line; its finding is shown with its quote

On #1805 run 42556446368 a lens was asked for a line and a quote, and the finding shown to the stages that fix it kept `file:line` and dropped the quote. Lines move as the change is made. A lens (review-lens and security-lens) is no longer asked for a line, and its finding reaches the stages that fix it as `(<file>: "<quote>"; fix: <what>)`. A line a model still sends is not passed on. ADR-067 §8 (amended the same day) says no stage names a line number.

## Enforced by

- §3 amendment 2026-11-09 (#2506: a lens names no line; its finding is shown with its quote) → `tests/unit/no-line-numbers-test.sh` L2, L3

- §3 §4 amendment 2026-11-08 (#2495: the scope is not judged) → `tests/unit/design-coverage-test.sh` NS1–NS3, X3; `tests/unit/judge-quotes-test.sh` Q2 (a scope line is no finding, and needs no line)
- §3 §4 amendment 2026-11-08 (#2491: a line per scope entry — removed by #2495) → `tests/unit/design-coverage-test.sh` NS1–NS3

- §3 amendment 2026-11-09 (#2505: a file name in formatting marks is the file) → `tests/unit/judge-quotes-test.sh` Q8

- §3 amendment 2026-11-07 (#2487: an escaped quote mark is the mark itself) → `tests/unit/judge-quotes-test.sh` Q7

- §5 amendment 2026-11-07 (last time's findings and their answers are shown; a grade holds) → `tests/unit/finding-answers-test.sh` C3; `tests/unit/finding-answers-test.sh` A2

- §4 amendment 2026-11-06 (#2477: a kept answer depends on the code its test exercises) → `tests/unit/judge-kept-code-test.sh` C1, C3, C4, C5
- §3 amendment 2026-11-06 (#2476: a failing test it cannot trace is UNSURE) → `tests/unit/issue-acceptance-test.sh` SPEC-12
- §3 §4 amendment 2026-11-05 (#2472: formatting aside; a bad line costs only its item; no dependency on the file the items come from) → `tests/unit/judge-quotes-test.sh` Q6; `tests/unit/judge-kept-partial-test.sh` D1, D2, P1
- §3 §4 amendment 2026-11-04 (#2470: answers per SPEC, kept per SPEC, the draft by its path) → `tests/unit/judge-feedback-test.sh` F4 (the draft by its path; only the SPECs judged, in full), F6 (one line per SPEC; kept per SPEC; requirements asked again when a SPEC changes; a dispute re-judges its SPEC only); `tests/unit/judge-events-test.sh` V4 (design's events per SPEC and `requirements`)

- §3 amendment 2026-11-04 (#2467: one line per part) → `tests/unit/gwt-judges-test.sh` J1–J8, T1–T9
- §2 §4 amendment 2026-11-04 (#2466: the copy and every kept answer leave events) → `tests/unit/judge-events-test.sh` V1–V5
- §1 → `tests/unit/judge-tools-test.sh` T1–T6
- §2 → `tests/unit/judge-base-code-test.sh` B1–B6; `tests/unit/judge-quotes-test.sh` Q2 (a [done] claim read on the old code, by file; no window), Q4 (no window); `tests/unit/descriptive-id-readers-test.sh` R10
- §3 → `tests/unit/judge-quotes-test.sh` Q1–Q5
- §4 → `tests/unit/judge-kept-test.sh` K1, K2, K4, K7, K8, K9
- §5 → `tests/unit/judge-kept-test.sh` K3, K5, K6, K7, K8; `tests/unit/design-stage-ids-test.sh` E5
- Amendment 2026-11-05 §3 (#2474) → `tests/unit/judge-reply-format-test.sh` F1–F5 (one shared step; each reader reads a formatted line)
