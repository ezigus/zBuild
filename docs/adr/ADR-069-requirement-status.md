# ADR-069 — Requirement status: needs work (code), needs work (no code), already done

**Status:** Accepted (2026-10-05); amended 2026-11-10 (#2517, §2 §4 §6 §11: every requirement is proven by a test at the end; a SPEC's tests are the branch's); amended 2026-11-10 (#2515, §2: a [done] whose evidence the branch moved is told so); amended 2026-11-09 (#2510, §10: every test and test helper of this repository lives in its test folders); amended 2026-11-09 (#2508, §3 §10: no test file is named; §11: a SPEC's test is found by its tag; §12: a requirement design does not understand is asked); amended 2026-11-09 (#2506, §2: no line number anywhere in the design); amended 2026-11-03 (#2464, §2: a [done] claim is read in the code from before the change, by file); amended 2026-11-04 (#2467, §1: a [code] or [done] SPEC has Given/When/Then parts); amended 2026-11-05 (#2474, §9: every SPEC, whatever its status, describes behaviour)
**Issue:** #2304; §9 #2305
**Amends:** ADR-036 (the acceptance check: the #1670, #1777, #2234 and #2244 guard rules are superseded), ADR-046 (design-gate C3/C4 rewritten, C6 removed), ADR-021 and ADR-053 (historical notes) — amended in PR B of #2304
**Carries out:** ADR-037's planned removal of the `[change]`/`[guard]` classification (ADR-037, the ADR-031 and ADR-036 rows of its retirement table)
**Related:** ADR-066 (every ADR statement has a test), ADR-067 (prompts speak plainly), ADR-068 (finding answers)

## Context

Design tags every requirement in the acceptance block `[change]` or `[guard]`. A `[change]` requirement's test must fail on the code from before the change and pass after it. A `[guard]` requirement's test must pass on the old code: it says something the code already does.

The guard rules did not pay for themselves. Across 23 issues (1,831 requirements):
- 27% of requirements were `[guard]`, and they caught zero real regressions. A guard is only ever run on the old code, so "the guard failed" always meant a wrong label or a broken test, never a regression.
- They cost about 7 engine fixes (#1670, #1777, #2234, #2244, …) and more than 15 hours of runs.
- The original reason for them (#1670: build writing a test that agrees with its own wrong code) is closed. test-author writes the tests before build, and build cannot edit them.
- Relabelling requirements as `[guard]` is how #2035 dropped its own red step: nothing it changed had to fail first.

ADR-037 already planned to remove the classification. This ADR says what replaces it.

## Decision

1. **Every requirement has one status, written as its tag.** `SPEC-n[code]:` needs work, and the work is code. `SPEC-n[no-code]:` needs work that changes no behaviour: docs, a test, config, or a refactor. `SPEC-n[done]:` is already done: the code already does it. A tag may contain a hyphen. The old tags keep being read during the transition: `[change]` means code, and `[guard]` means done. A requirement with no tag, or with a tag none of these name, has no status (design-gate rejects it).
2. **The design-gate checks every status, and an "already done" requirement names evidence that exists.** The evidence ends the requirement's line, after ` evidence: ` — one or more items separated by spaces, each a repo-relative `file` or `file:N` (no leading `/`, no `..`). The file must exist and `N` must be a line inside it. The evidence is not part of the requirement's text. The design-gate (C3) rejects a requirement with no status (`NO_STATUS`), an unknown tag or the retired `[guard]` (`UNKNOWN_STATUS`), a `[done]` with no evidence (`DONE_NO_EVIDENCE`), and an evidence item that does not point at the repository (`DONE_BAD_EVIDENCE`), and says each in plain words. Design is told the three statuses and the evidence syntax. When the acceptance check says a `[code]` requirement's test already passes on the old code, design is told to rewrite it so its test fails there, or — if the code already does it — to mark it `[done]` with evidence. There is no offer to relabel: `[done]` is a claim the gate checks, not a way to drop the red step (#2035).
3. **A code requirement keeps the existing rule:** its test must fail on the code from before the change and pass after it. `[code]`, the old `[change]`, and an untagged requirement are all checked this way. *Amended 2026-11-09 (#2508):* no requirement names a test file; design-gate C4 is gone (§11).
4. **No-code and done requirements are not run against the old code.** The acceptance check prints `NEGCTL SKIP <id> already_done` or `NEGCTL SKIP <id> no_code` for them, and does not ask them for a tagged assertion (Level 1). With no code requirement at all, nothing is run. The pass reason counts the requirements checked on the old and new code, already done, and needing no code.
5. **Code nobody claims fails the acceptance check.** If the branch (merge-base to HEAD) changes production code and the acceptance block's requirements include no code requirement, the check fails. It names the files, and says what to add: "this change edits code (scripts/x.sh) but no requirement says what that code must now do — add a [code] requirement with a test". Production code is every path except `tests/`, `plugins/<kind>/<id>/tests/`, `docs/` and `*.md` files. An untagged requirement counts as code, because the negative control still checks it as code. The failure class is `unclaimed_code` (recoverable: design can add the requirement next round), and the event is `acceptance.gate.unclaimed_code`. A block that names no requirement ids has no status to read, so this check is silent for it.
6. **test-author writes no test for a done requirement, and build is not asked to make one.** test-author leaves a done requirement out of its prompt; a design whose requirements are all done completes with no model call. A no-code requirement's test must pass after the change and need not fail before. Build's list of requirements leaves out the done ones. The review lenses read each status in plain words, with a done requirement's evidence.
7. **issue-acceptance judges what nothing else checked, and says when a person must.** It reads every requirement as its words and, in plain words, its status: a code requirement's test failed on the old code and passes now; a no-code one was checked by nothing, so the judge judges it and says whether its tests would catch it broken; a done one is a claim to check, shown with its evidence and up to 20 lines around each cited line, read from the commit at HEAD, cleaned for the model, and bounded in total. No raw `[code]`/`[no-code]`/`[done]` tag reaches it. It may answer `VERDICT: unsure` with `UNSURE:` naming the requirements it cannot tell are met. Any requirement named there makes the result a fail; `data.unsure` lists them, each is a numbered finding saying what is unresolved and what would settle it (a test that fails when the requirement is not met, or the code or document that shows it is met) — never who must check it (#2330) — and the stage emits `issue_acceptance.unsure`. The finding goes round the loop like any other (ADR-068): design and build see it and say what they did about it. If it is still listed when the loops run out of rounds, the run stops and every report lists it (ADR-068 §8). spec-coverage, which reads the issue before any code exists, counts a requirement an already-done SPEC covers as covered — issue-acceptance checks the claim — and keeps its exemption for how a change is verified.
8. **No `[guard]` path is left, and no model is offered the tag.** PR B removed the guard half of the negative control, design-gate C6, the guard reasons, classes and event, and the guard text in the design, test-author, build and review-lens prompts. Engine code (`core/`, `scripts/`, `plugins/`, tests excluded) names none of `guard_regressed`, `_negctl_guard_`, `acceptance_spec_is_guard` or `guard_precheck`. Model-facing text never contains `[guard]`: the plain-prompt lint refuses it, and the design-gate's message for an old `[guard]` requirement names "the old guard tag" without writing it. The parser still reads an old `[guard]` line, as done, only so a design written before this change is read sensibly and the design-gate can name it and reject it (§2).
9. **A code requirement describes behaviour, not file contents (#2305).** A requirement such as "plugin.sh contains `_foo`" or "file X exists" fails on the old code and passes on the new, so §3 accepts it while it proves nothing about what the code does. The design-gate (C3) reads the words of every `[code]` (and old `[change]`) requirement and rejects one (`CONTENTS_NOT_BEHAVIOUR`) when all three hold: it names a file (a path, a file with a source extension, or the word file, manifest, source, script or function); it uses a contents verb (contains, defines, declares, exists, is present, has a … key, field, entry or function, greps); and it has no behaviour word (returns, emits, writes, fails, prints, exits, rejects, skips, stops, runs, refuses, outputs, logs, calls, reports, passes, creates, removes, produces, reads, sends, or when, if, whenever, unless, given). Names in backticks or double quotes are not read as verbs. The message says: "SPEC-n describes what a file contains, not what the code does — no test can prove that; describe the behaviour someone could observe (an input and what happens)". Every requirement is checked, whatever its status (amended 2026-11-05, #2474; `[done]` and `[no-code]` were not checked). The lists are kept short on purpose, because a false match blocks a real design. The trade-off is deliberate and runs one way: a missed fake requirement costs less than a blocked real design. Behaviour words match any ending, so a word such as "runner" or "reader" lets a contents-only sentence through; and a verb written in backticks is read as a name, so it is not checked. Both are known, and accepted. Design is told the rule in its prompt.
10. **A test file is in one of the repository's test folders (2026-10-26).** *Amended 2026-11-09 (#2508):* design lists no test file, so there is no `TESTFILES:` path to check; the test folders are where a requirement's test is found (§11) and what test-author owns (ADR-030 §8). Before: every path under `TESTFILES:` had to match one of the repository's test folders, or design's checks rejected the design and said why in plain words. The folders are data, not code: the engine's `config/test-paths.txt` (`tests/*`, `plugins/*/*/tests/*`), which a repository replaces with its own `.zbuild/test-paths.txt`. The acceptance check's own idea of a test file (§5) reads the same list. #1801 run 40390919951 named two ADR documents as a requirement's tests; the test stage ran them with bash, and their markdown quote lines (`> word`) created files in the worktree.

**Amendment (2026-10-05, #2306, ADR-070 §3):** a requirement line may also carry ` covers: ` and the issue requirement ids it covers, before the ` evidence: ` part. The covers part is not part of the requirement's text or its evidence.

## Consequences

- A change cannot ship code under "no code" or "already done" labels alone (§5), and "already done" must point at the code that does it (§2).
- A `[guard]` requirement no longer passes the design-gate. A design written before this change is rejected there once, with a plain message saying which status to use, and design rewrites it.
- The fork budget goes down: a done or no-code requirement costs no test run, and a design with no code requirement makes no worktree.

## Implementation Notes (#2304 PR C)

- `scripts/lib/acceptance-block.sh`: `acceptance_requirements_for_judge` renders the requirements for issue-acceptance (status words, evidence, excerpts read with `git show HEAD:<path>`, 6000 characters of excerpts in all). The plugin cleans the text with `_zbuild_sanitize_for_llm`.
- `plugins/agent/issue-acceptance/plugin.sh`: the reply may be `VERDICT: unsure` with an `UNSURE:` line; `none` is read as nothing. The manifest declares `issue_acceptance.unsure`.
- `scripts/lib/lint-plain-prompts.sh`: `\[guard\]` joins the refused words.

## Implementation Notes (#2304 PR B)

- `scripts/lib/acceptance-negctl.sh`: the guard arm, the baseline-only verdict, the design-gate pre-check and their helpers are gone. Each SPEC's status is read once per check; done and no-code SPECs are skipped before anything runs. `_negctl_guard_log_check` is now `_negctl_spec_log_check` (shared with `acceptance-reachability.sh`).
- `scripts/lib/acceptance-block.sh`: `acceptance_spec_is_guard`, `acceptance_spec_classifier` and `acceptance_spec_is_change` are removed; callers read `acceptance_spec_status`.
- `plugins/tool/design-gate/plugin.sh`: C3 (status, evidence) and C4 (`[code]` only) rewritten; C6 and the `guard_precheck` block removed; the gate no longer sources the negative-control library.
- `plugins/agent/spec-acceptance`: the guard reasons, the `acceptance.gate.guard_regressed` event and the guard classes are removed (also from `scripts/lib/acceptance-disposition.sh`); the pass reason counts each status.

## Implementation Notes (#2304 PR A)

- `scripts/lib/acceptance-block.sh`: one requirement-line pattern, `_ACCEPTANCE_SPEC_RE`, used everywhere a `SPEC-n[tag]:` line is read. `acceptance_spec_status`, `acceptance_spec_evidence`, and `acceptance_spec_text` (now without the evidence) read a requirement through `_acceptance_spec_line`, which sets variables instead of printing, so it costs no extra fork. The old `[change]`/`[guard]` helpers stay until PR B removes them.
- `scripts/lib/acceptance-negctl.sh`: `acceptance_unclaimed_code_check`, with `_acceptance_is_test_path` (the test-path rule from #2300, now shared with the `no_prod_delta` skip) and `_acceptance_is_production_path`.
- `plugins/agent/spec-acceptance/plugin.sh`: the check runs first (Level 0) and is reported in the same pass as the other levels. The manifest declares the event and the failure class; `scripts/lib/acceptance-disposition.sh` maps the class to recoverable.

## Amendment 2026-11-01 (#2445) — §2: a [done] claim is judged against its code

The scripted check confirms that a `[done]` requirement's evidence exists. Design's coverage check is now
also shown the lines that evidence points at and judges whether that code does what the requirement says
(ADR-070 §4, amended 2026-11-01), so a wrong "already done" is caught in the round that wrote it.

## Amendment 2026-11-03 (#2462) — §1: a SPEC's id describes it and never moves; §2: [done] is proven on the code from before the change

On #1805 run 41582195372 design marked the core of the issue `[done]` with evidence in code last run's build
had written on the reused branch: a `[done]` requirement has no test and the old-code check skips it, so the
main behaviour would have shipped untested. Its evidence was a line number (`runner.sh:3808`), which moved to
3896 between tries.

- **§1: a SPEC's id describes it.** `<code>-<n>` like a requirement's (ADR-070 §1, amended 2026-11-03): 3 or 4
  capital letters or digits starting with a letter, a dash, a number. Every reader matches ids with one
  pattern, `_ACCEPTANCE_ID_ERE` (`scripts/lib/acceptance-block.sh`), and the old `SPEC-<n>` is an id of that
  shape, so earlier issues' ids and `[SPEC-n]` / `[#<issue>/SPEC-n]` tags read as before and are never changed.
  A new design does not use the code `SPEC` (`ID_OLD_FORM`); its old ids need no REMOVED line.
- **§1: an id never moves** (design's checks, C9, no model). Held to the last design that passed: an id it had
  is kept or listed `REMOVED: <id> — <why>` in the acceptance block (`ID_DROPPED`); a removed id stays listed
  (`ID_REMOVED_LOST`) and never comes back (`ID_REUSED`); a new id's number is one more than its code's highest,
  removed ones counted, never skipping one (`ID_NOT_AFTER_LAST`); a REMOVED line names an id the last
  design had (`ID_REMOVED_UNKNOWN`). Also refused: a duplicate (`ID_DUPLICATE`), a line shaped like an
  id with a bad code (`ID_BAD`), a code the issue's requirements use (`ID_OTHER_POOL`), an id the issue's own
  text writes (`ID_IN_ISSUE`, read from the requirement list's `issue_ids`). test-author's stale-tag step reads any id of this issue's.
- **§2: `[done]` means the code from before the change already does it** (as §3–§4 always measured it). Its
  evidence is a file with an exact piece of its text, `file:"text"`, or a test file named alone — never a line
  number (`DONE_LINE_EVIDENCE`): lines move as the change is made. The text must be in the file on the base
  commit (the merge-base with the default branch) and still in it outside every line this branch added or
  changed (`DONE_NOT_BEFORE`); a source file named alone is refused (`DONE_NO_TEXT`), and text not in the file
  (`DONE_TEXT_MISSING`). The words tell design to tag such a requirement `[code]` and give it a test. With no
  base commit, the text in the file is what is checked. The coverage check and issue-acceptance show the code
  around the line holding the text.

## Amendment 2026-11-03 (#2464) — §2: a [done] claim is read in the code from before the change, by file

The checks that judge a `[done]` claim — design's coverage check and issue-acceptance — are pointed at each evidence item's file and text, and open the file themselves. They are never given a window of lines; the windows (10 lines in the coverage check, 20 in issue-acceptance) are gone. The coverage check reads the claim in a read-only copy of the base commit (ADR-072 §2), because the claim is about the code from before the change; before this amendment it read the branch's own working copy. On #1805 run 41679237388 it ruled SKIP-1's claim wrong from ten lines, with the line that proved it just past them.

## Amendment 2026-11-04 (#2467) — §1: a [code] or [done] SPEC has Given/When/Then parts

A requirement marked `[code]` or `[done]` says its behaviour as parts under its line: Given, one When, at least one Then, and Cleanup when something outlives the test (ADR-073 §1). A `[no-code]` requirement may have them. The status and evidence stay on the first line.

## Amendment 2026-11-05 (#2474) — §9: every SPEC, whatever its status

#1805 run 42090130741's design passed BNDY-1, a `[no-code]` SPEC saying what a test file contains. No test can prove that; test-author's check found it, and it ended the run.

- **The contents check reads every requirement**, `[code]`, `[no-code]` and `[done]` alike. A doc change is written as what a reader is told, not as what the file contains.
- **A behaviour word is a word of its own.** A hyphenated word is one word, so "fresh-run" does not count as "runs": BNDY-1 got through on it.
- The message no longer suggests marking such a requirement `[done]`, since `[done]` is checked too. Design's prompt says the rule holds for every status.

## Amendment 2026-11-06 (#2482) — §1: ids start with design's prefix, and a failed try's SPEC may be removed; §2: design is shown the code from before; §7: the judge sees the whole branch

#1805 run 42293991602 failed with `out_of_tries:design`. Design claimed twice that code this branch had written was already done, and the check refused both claims (verified from round 3's transcripts).

- **§1, the prefix.** Every SPEC id starts with design's `id_prefix` (`DS`, ADR-001): `DSLOOP-1`. An id without it is refused (`ID_NO_PREFIX`), with a plain sentence naming the prefix. A SPEC may share a requirement's code, because the prefixes keep them apart, so the rule that a SPEC's code is never a requirement's (`ID_OTHER_POOL`) is gone. An id from an earlier design without the prefix is the old numbering, like `SPEC-n`: it gets a new id once and needs no REMOVED line. Design's prompt is given the prefix from its manifest, and every example id in it carries the prefix.
- **§1, removal.** A `REMOVED:` line may name a SPEC that a try of this run wrote and that did not pass. The check reads those tries' drafts in the try archive (`attempts/<stage>/…/design-draft.md`; a draft older than the run's start marker is not this run's). In the run, try 2 removed GUAR-3, which only the failed try 1 had, and lost the try to that line alone.
- **§2.** Design's prompt names the copy of the commit the branch started from, the same copy the judges read (ADR-072 §2). It says a `[done]` claim is checked there, and to open the file there, not in the working copy. The `[done]` rule now says "the commit this branch started from" rather than "the default branch": the merge-base, which other work landing on main does not move. In the run, design believed it could not look at older code ("Since I can't pull the git history here"). It took the judge's "not in this incremental DIFF" as proof that the code was old, and grepped only its working copy.
- **§7.** issue-acceptance judges the change from where the branch started to now (`zbuild_change_bundle`, as the review lenses do), not build's `diff.patch` for this round alone. With no base commit it reads `diff.patch` as before. In the run it wrote of code an earlier round had added: "it is not in this incremental DIFF".

## Amendment 2026-11-09 (#2506) — §2: no line number anywhere in the design

#2462 refused a line number only in a `[done]` SPEC's evidence. On #1805 run 42556446368 design's decisions and findings still cited lines such as `runner.sh:3442` as verified facts, and later stages read them after the lines had moved. Design's check now refuses a line number anywhere in the design — `<file>:<digits>`, in a decision, a finding or any other text (`LINE_NUMBER`) — and says: name the file and the function, or quote the text. A quote, `<file>:"<text>"`, is no line number. A `[done]` evidence line number is reported once, as `DONE_LINE_EVIDENCE`. ADR-067 §8 (amended the same day) says no stage names a line number.

## Amendment 2026-11-09 (#2508) — §3 §10: no test file is named; §11: a SPEC's test is found by its tag; §12: a requirement design does not understand is asked

#1805 run 42556446368 ended on a file no list named. Test-author's new test needed a template; design's `TESTFILES:` did not name it; test-author's commit took only the listed files, and build's scope check counted the stray file as build's. Design had guessed every test file, and every file of the change (its scope block, ADR-030), before any code or test existed, and its misses kept ending runs. Nobody settled what the issue meant either: whether `--from-stage` needs `--resume` was not in the issue; design never decided, and issue-acceptance said "no requirement" one run and "correctly works standalone" the next.

11. **Design names no files.** No `TESTFILES:` block — no test file per SPEC (C4, `MISSING_TESTFILE_FOR_SPEC`), no test-folder check of one (C8, `TESTFILE_NOT_A_TEST`) — and no ```scope block (C1, `SCOPE_MISSING`; ADR-030 §8). Which file holds a SPEC's test is found from its tag (`[#<issue>/<id>]`, or `[<id>]` on a goal run): every file in the repository's test folders, committed or not, that holds it (`acceptance_spec_files_v`, `scripts/lib/acceptance-block.sh`). A tagged file outside the test folders is not a test. Every reader of the old list reads this: the acceptance check (tag coverage, the negative control, reachability, its readout), test-author (its prompt, its run on the old code, its record and stale tags), build's acceptance tests, the review lenses, the test stage's targeted set and its finding owners (ADR-071 §1). An old design's `TESTFILES:` list is skipped, never read, and its lines are not read as SPECs. A WIRING file in a test folder is still refused (`WIRING_IS_TEST`, #2429: reachability cannot prove a test load-bearing), now by the test folders.
12. **A requirement design does not understand is asked, not guessed in silence.** Design writes one line for it outside the fenced blocks — `UNCLEAR: <id> | <the question> | <what it assumed>`, `<id>` the requirement's — and carries on with that assumption. Design's checks refuse an UNCLEAR line not in that form (`UNCLEAR_MALFORMED`), so no question is dropped. The questions are shown, with the assumptions, in the live run-status comment (ADR-064 §4), in the report of a failed run (ADR-068 §8) and in the PR's description (ADR-040).

## Amendment 2026-11-09 (#2510) — §10: every test and test helper of this repository lives in its test folders

The test folders decide who may do what (#2507, #2508): test-author owns them, build may not change them, and a SPEC's tests are found by searching them. A test or a helper outside them escapes all three. In this repository the main test helper sat beside engine code in `scripts/lib/`, six tests sat in `core/*/tests/`, and the repository had no list of its own.

- **Every test and test helper of this repository lives in its test folders**: `tests/`, and a plugin's own `tests/` folder (a plugin is a self-contained package). The test helpers are in `tests/lib/` (`test-helpers.sh`, `golden.sh`, `parity.sh`, `fork-census.sh`); the tests that were in `core/{pipeline,cache,state,router}/tests/` are in `tests/unit/`, and `scripts/run-tests.sh` no longer looks in `core/`.
- **A script outside the test folders that tests source and no production file sources or runs is refused**: it is a test helper beside production code. `scripts/lib/lint-test-helper-place.sh` (in `npm run lint`) reads the repository's own list.
- **This repository declares its test folders in `.zbuild/test-paths.txt`.** The engine's `config/test-paths.txt` stays the default for a repository that declares none; the two say the same today only because this repository is also the engine.

## Amendment 2026-11-10 (#2515) — §2: a [done] whose evidence the branch moved is told so

On #1805 run 42732752714 design marked RQFROM-4 `[done]`, quoting a line the code from before the change has. The branch had moved that line, so every place it appears now is a line the branch changed, and the check rightly refused it: what runs now is the branch's code. But its words said the text was not in the code from before the change. Design found it there, answered `wrong` twice, and ran out of tries.

- **The two cases have their own words.** Text not on the base commit is `DONE_NOT_BEFORE`: "not in the code from before this change — this branch added it". Text on the base commit, but now only on lines the branch moved or changed, is `DONE_MOVED`: "is in the code from before this change, but this branch has since moved or changed every line that holds it. What runs now is this branch's code, not the old one, so it is not done". Both tell design to tag it `[code]` and give it a test.

## Amendment 2026-11-10 (#2517) — §2 §4 §6: every requirement is proven by a test at the end; §11: a SPEC's tests are the branch's

On #1805 run 42817975218 no status fitted DSFSTG-4, a requirement main already met and the branch had broken by moving a line. Tagged `[code]`, its test could not fail on main; tagged `[done]`, its quoted line was one the branch had moved. Design swapped between them and ran out of tries. A `[done]` was proven by a quoted line of main's code and nothing else, so it could not tell "still done" from "the branch broke it". The same run took an engine test holding `[#1805/DSFSTG-1]` as sample text for DSFSTG-1's test.

- **§4 §6: every requirement, whatever its status, has a test that passes at the end.** test-author writes one for a `[done]` requirement too (a design whose every requirement is done still calls it); the acceptance check asks every requirement for its tagged test (Level 1); only a `[code]` requirement's test must also fail on the code from before the change. A `[done]` or `[no-code]` test need not fail there. test-author's run on the old code reports a `[done]` test that fails there: the old code is said to do it, so the test or the `[done]` is wrong.
- **§2: `[done]` evidence shows where the old code does it, and is no longer refused for a line the branch moved or changed** (`DONE_MOVED`, #2515, is gone). Text the old code does not have is still refused (`DONE_NOT_BEFORE`). Design's prompt says a `[done]` SPEC still gets a test.
- **§11: a SPEC's tests are found only among the test files this branch added or changed** since it left the default branch, committed or not (`zb_test_folder_branch_files_v`). On the default branch itself, or with no base to compare with, every file in the test folders.

## Enforced by

- §2 §4 §6 amendment 2026-11-10 (#2517: every requirement is proven by a test at the end) → `tests/unit/test-author-before-run-test.sh` B11 (a [done] requirement is in test-author's prompt with its tag and what its test must do; an all-done design still calls the model; a [done] test passing on the old code is no finding, failing there is); `tests/unit/acceptance-coverage-test.sh` C7, C9 (a [done] or [no-code] SPEC needs its tagged test); `tests/unit/design-stable-ids-test.sh` D16 (a [done] whose evidence the branch moved is accepted), D11 (text the old code lacks is still refused)
- §11 amendment 2026-11-10 (#2517: a SPEC's tests are the branch's) → `tests/unit/design-names-no-files-test.sh` N11

- §2 amendment 2026-11-10 (#2515: a [done] whose evidence the branch moved is told so) → `tests/unit/design-stable-ids-test.sh` D11 (text not in the old code keeps its words), D16 (text the old code has, on a line the branch moved, gets the moved words and never "not in the code from before")

- §2 amendment 2026-11-09 (#2506: no line number anywhere in the design) → `tests/unit/no-line-numbers-test.sh` L4, L5

- Amendment 2026-11-09 (#2508) §3 §10 §11 → `tests/unit/design-names-no-files-test.sh` N1 (a design with no `TESTFILES:` and no scope block passes design's checks), N2–N6 (a SPEC's test is the test-folder file holding its tag, committed or not; not a document, not another issue's tag; a repository's own test folders decide), N7 (an old design's list is not read, nor its lines taken for SPECs), N8 (design is asked for neither); `tests/unit/test-author-owns-test-folders-test.sh` O2 (test-author's new test is found by its tag and committed); `tests/integration/build-never-touches-tests-test.sh` B5 (build is given no file list)
- Amendment 2026-11-09 (#2508) §12 → `tests/unit/design-names-no-files-test.sh` N9 (design is told the UNCLEAR form and to carry on with its assumption), N10 (a malformed UNCLEAR line is refused, in plain words; a well-formed one passes); `tests/unit/unclear-questions-shown-test.sh` Q1–Q5 (the questions reach the run-status comment, the failed run's report and the PR description)

- Amendment 2026-11-09 §10 (#2510) → `tests/unit/test-folders-test.sh` F1–F3, F7 (a script production code loads by a computed name, `providers/$p.sh`, is not a test helper) (a helper beside production code, sourced only by tests, is refused by name; a library production code sources and a script it runs are not; a helper in the repository's own test folders passes), F4 (the real tree has none), F5 (this repository's folders are read from its `.zbuild/test-paths.txt`), F6 (every `*-test.sh` file is inside them)
- Amendment 2026-11-06 (#2482) §1 → `tests/unit/design-stable-ids-test.sh` D6 (no prefix, or another stage's, refused in plain words; a SPEC may share a requirement's code), D8 (ids from before the prefix need no REMOVED line), D15 (a REMOVED line may name a failed try's SPEC; a draft from before the run does not count); `tests/unit/design-prompt-scope-charter-test.sh` T9 (the prompt gives the prefix; every example id has it); `tests/unit/descriptive-id-readers-test.sh` R1–R12 (every reader reads a prefixed id); §2 → `tests/unit/design-prompt-scope-charter-test.sh` T8 (the prompt names the copy of the code from before, which holds the branch's starting code); §7 → `tests/unit/issue-acceptance-test.sh` SPEC-13 (a line an earlier round added is in the judged change)
- §1 amendment 2026-11-04 (#2467: Given/When/Then parts) → `tests/unit/gwt-format-test.sh` C1–C5
- §2 amendment 2026-11-03 (#2464: read in the code from before, by file) → `tests/unit/judge-quotes-test.sh` Q2, Q4; `tests/unit/descriptive-id-readers-test.sh` R10; `tests/unit/judge-base-code-test.sh` B1–B6
- §1 §2 amendment 2026-11-03 (#2462: descriptive ids that never move; [done] proven on the code from before) → `tests/unit/design-stable-ids-test.sh` D1–D14; `tests/unit/design-stage-ids-test.sh` E1–E4; `tests/unit/descriptive-id-readers-test.sh` R1–R12
- §2 amendment 2026-11-01 (#2445) → `tests/unit/design-coverage-test.sh` X4, X5

- §1 → `tests/unit/requirement-status-test.sh` S1 (a `[no-code]` requirement is listed), S2 (the status of each tag, including `[change]` → code and `[guard]` → done), S3 (evidence is split from the requirement text)
- §5 → `tests/unit/acceptance-unclaimed-code-test.sh` U1–U4 (U4 runs the gate's own entry); `tests/unit/acceptance-disposition-classify-test.sh` (`unclaimed_code` is recoverable)
- §2 → `tests/unit/design-checks-test.sh` G1 (no status), G2 (`[guard]` and an unknown tag rejected; `[change]` and `[no-code]` accepted), G3 (`[done]` with no evidence), G4 (evidence that exists passes; absolute, `..`, missing, out-of-range and non-numeric lines are rejected); `tests/unit/design-checks-plain-test.sh` D2 (each said in plain words); `tests/unit/design-acceptance-block-test.sh` T6 (the design prompt explains the three statuses and the evidence syntax, and offers no `[guard]`/`[change]`); `tests/unit/design-prior-gate-feedback-test.sh` T1 (the acceptance-failed re-prompt says rewrite or `[done]` with evidence, and has no relabel offer)
- §3 → `tests/unit/acceptance-negctl-status-test.sh` N4 (`[code]`, `[change]` and untagged requirements are still checked on the old and new code); `tests/unit/design-names-no-files-test.sh` N1 (since #2508 no requirement names a test file)
- §4 → `tests/unit/acceptance-negctl-status-test.sh` N1 (`[done]` not run), N2 (`[no-code]` not run), N3 (tag coverage exempts both), N5 (the pass reason counts each status); `tests/unit/acceptance-coverage-test.sh` C7, C9
- §6 → `tests/unit/test-author-test.sh` T1 (a done requirement is left out; a no-code one need not fail before), T2 (all done → no model call); `tests/unit/build-prompt-spec-text-test.sh` B1 (build's list leaves out done); `tests/unit/review-lens-requirements-plain-test.sh` L5 (each status in plain words, with evidence)
- §7 → `tests/unit/issue-acceptance-status-test.sh` I1 (each status in plain words, a done requirement's evidence and a bounded excerpt from HEAD, cleaned; no raw tag), I2 (not sure → fail, `data.unsure`, a finding saying what would settle it and never who must check it, the `issue_acceptance.unsure` event declared in the manifest); `tests/unit/design-coverage-test.sh` SPEC-9 (an already-done SPEC covers its requirement; the verification exemption is kept); an unsure item still open at the end is listed by every report, enforced by `tests/unit/run-open-items-test.sh` O1
- §9 → `tests/unit/design-checks-test.sh` G7 (contents and existence requirements rejected, with the plain message; a contents-only requirement is refused beside a sound one; behaviour requirements, `[done]` and `[no-code]` pass); `tests/unit/design-acceptance-block-test.sh` T6 (the design prompt says a `[code]` requirement describes behaviour)
- §10 → `tests/unit/design-names-no-files-test.sh` N3, N5 (a requirement's test is found only in the test folders, and a repository's `.zbuild/test-paths.txt` replaces the default); `tests/unit/acceptance-unclaimed-code-test.sh` U3 (the acceptance check reads the same list)
- §8 → `tests/unit/no-guard-paths-test.sh` N1, N2 (no retired guard path in engine code); `tests/unit/lint-plain-prompts-test.sh` P9 (`[guard]` in model-facing text is refused) and P6 (the real tree passes); `tests/unit/design-checks-test.sh` G2 (the old-tag message does not write the tag)
- Amendment 2026-11-05 §9 (#2474) → `tests/unit/design-checks-test.sh` G7 (`[done]`, `[no-code]` and #1805's BNDY-1 refused; a doc requirement about what a reader is told passes); `tests/unit/design-acceptance-block-test.sh` T6 (the prompt)
