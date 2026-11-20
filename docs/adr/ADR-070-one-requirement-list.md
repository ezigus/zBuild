# ADR-070 — One fixed list of requirements per issue

**Status:** Accepted (2026-10-05); amended 2026-11-20 (#2571, §1: what intake finds unclear in the issue is a question in the one form, kept in its result, and judged by its check each try); amended 2026-11-20 (#2569, §1: a missing requirement the check names is the issue's own sentences, checked; §2: the last list is a starting point, not the whole issue); amended 2026-11-16 (#2555, §1: an issue's ## Terms section reaches every stage word for word); amended 2026-11-15 (#2550, §1: an item the issue says not to do is a limit, kept with its "Do not"; intake numbers ids from its check's own count); amended 2026-11-12 (#2527, §1: intake's check is shown each removed item with its words and why, and is never told to name a listed id; §4: design's coverage check takes a quote from the issue's words too); amended 2026-11-08 (#2495, §4: the check looks both ways through the SPECs only, and does not judge the scope); amended 2026-11-09 (#2508, §4: design writes no scope block; what build changes is held to the requirements by issue-acceptance)
**Issue:** #2306
**Amends:** ADR-046 (design-gate gains C7), ADR-069 §2 (a requirement line may also carry ` covers: `)
**Related:** ADR-055 (inter-stage data contract), ADR-040 §5 (spec-coverage judges against the issue), ADR-066 (every ADR statement has a test), ADR-067 (prompts speak plainly)

## Context

Every stage read the issue's prose and decided for itself what it asked for. On #2035 the issue said "SPEC-2" and "SPEC-3", meaning assertion labels inside a test file. Design, spec-coverage and issue-acceptance read them as design's own SPEC numbers and matched on names instead of content. Three readers of the same prose produced three different requirement lists, and nothing mechanical could say whether the design covered the issue.

Identifiers taken from prose are not deterministic. The engine has to number the requirements itself, once, and every later stage has to read that one list.

## Decision

1. **Intake writes one numbered list.** For an issue run, intake writes `artifacts/requirements.json`: `{"schema_version":1,"source":"checkboxes"|"title","requirements":[{"id":"R-1","text":"…"},…]}`. The source is every checkbox line of the issue body (`- [ ]` or `- [x]`, any bullet, any indent, under any heading), outside code fences, numbered R-1, R-2, … in order by code. The words are kept as written (control characters removed, ends trimmed); an identifier in them, such as `SPEC-2`, is text, never an id. An issue with no checkbox has one requirement, R-1: its title and the body's first paragraph, with `"source":"title"`. Comments are not read for the list.
2. **The list is a declared output, and only an issue has one.** intake's manifest declares the output `requirements` (`${artifact_dir}/requirements.json`, `required: false`), and design, design-gate, spec-coverage and issue-acceptance declare it as an input (`required: false`), so it reaches them through the engine's input index (ADR-055 §1). A goal run writes no list, and intake removes a list an earlier run left in the artifact directory.
3. **Design maps every requirement; a script checks it.** Design is shown the list and ends each SPEC line with ` covers: ` and the ids it covers, before any ` evidence: ` (`SPEC-1[code]: <behaviour> covers: R-1 R-3`). The parser (`scripts/lib/acceptance-block.sh`) keeps the covers part out of the requirement's text and its evidence, in either order, and `acceptance_spec_covers` returns the ids. The design-gate (C7, no model) fails a design when any R in the list is covered by no SPEC, whatever the SPEC's status — an already-done requirement is covered by a `[done]` SPEC — and names each uncovered R with its words (`REQUIREMENT_NOT_COVERED`). With no list, the check is skipped.
4. **The judges judge the list.** spec-coverage and issue-acceptance are shown the list (each `- R-n: <text>`) beside the issue text, judge every R by its words, and name a gap by its id and words. The issue text stays as context for what a requirement means. With no list, they read the requirements from the issue as before.

## Consequences

- Requirement ids are the same for every stage of a run and are never read from prose, so "SPEC-2" in an issue can no longer be mistaken for design's SPEC-2.
- A design that drops a requirement fails before build, by script, and the message names the requirement — spec-coverage no longer has to be the first to notice.
- An issue with no checkboxes becomes one broad requirement; writing the acceptance list as checkboxes is how an issue author gets each item checked on its own.

## Implementation Notes

- `plugins/agent/intake/lib/requirements.sh`: `_intake_requirements_json` (one jq program) and `_intake_write_requirements`; `plugin.sh` calls it after a successful fetch.
- `scripts/lib/acceptance-block.sh`: `_acceptance_spec_line` sets `_ACC_SPEC_COVERS`; `acceptance_spec_covers`; `acceptance_requirements_list` renders the list for prompts.
- `plugins/tool/design-gate/plugin.sh`: C7 collects the covers ids while reading each SPEC's status (no extra fork per SPEC).

## Amendment 2026-11-01 (#2445) — §1: a model writes the list, a second checks it; §4: the design check looks both ways

**§1.** Intake took only checkbox lines, so an issue that wrote its requirements as a numbered list or as
prose became one requirement (#2443's five changes reached every check as a single R-1). Intake now writes
the list with a model call given only the issue — its requirements in the issue's words, one per line — and
a second call, given the issue and the list, names what the list misses; that is added. Each call has one
turn (`config.router.max_turns: 1`), so neither can open the code. The engine still numbers the list R-1,
R-2, … and `"source"` is `"model"`. A call that fails ends intake with that call's outcome, so the engine can
run it again, and no list is written. The checkbox scraping is gone.

**§4.** Design's coverage check also looks the other way: every SPEC or scope entry that commits to
something the issue does not ask for, or contradicts it (`OUTSIDE:`). It is always shown the design's scope,
and for each `[done]` SPEC the lines its evidence points at, and names each one whose code does not do what
it says (`DONE_WRONG:`, ADR-069 §2). Each item is a finding design must fix, whatever the coverage verdict.
*Amended 2026-11-08 (#2495):* the scope is no longer judged; see the amendment below.

## Amendment 2026-11-01 (#2448) — §1: intake's calls have no tools

Each of intake's two calls has one turn and no tools (`config.router.tools: none`, ADR-017 §11): it is given the issue and answers in its reply. One turn alone did not keep it out of the code. With its tools on, try 1 on #1805 spent its turn on a tool call and ended `out_of_turns`.

## Amendment 2026-11-02 (#2460) — §1 §2: intake starts from its last list and says what changed; one item per line

Over the same issue text intake listed 17, 15, 15, 14 and 16 requirements in successive runs of #1805 — its
check call finds different misses each time — and said nothing; on run 41546214211 the two it added made
design's first try fail.

- **§2: the last run's list is kept in hand, never read as this run's.** intake's writing call is shown it and
  told to start from it — keep each requirement the issue still states, in the same words; add any it misses;
  leave out any the issue no longer asks for. The latest list is the one kept.
- **§2: intake says what changed.** Its result carries `requirements_changed` (`added`, `removed`, by their
  words) and its summary says "the requirements changed since the last run", naming each, or that they are
  the same as the last run's.
- **§1: one item per line.** The check answers one `MISSING:` line per requirement it finds missing; a reply is
  read in whole units (`scripts/lib/reply-units.sh`), so a requirement that wraps, or holds a `;`, is one.

## Amendment 2026-11-03 (#2462) — §1 §2: each id describes its requirement and never moves; a removal says why

Ids were positions (R-1, R-2, …). On #1805 run 41582195372 intake's second try wrote 14 requirements instead
of 16, in a new order, so every R-n named a different requirement than design's kept work did, and design
spent three tries on numbering alone. That try had never seen the last list: intake deleted it at the start
of the first try, which then failed. The first try had been shown the list as bullets and answered in bullets.

- **§1: an id describes its requirement.** It is a code of 3 or 4 capital letters or digits, starting with a
  letter, that says what the requirement is about, a dash, and a number (`LOOP-1`). The model writes it on each
  line, `REQUIREMENT: <id> <words>`, and the check call writes `MISSING: <id> <words>`. Nothing in the engine
  names a code, so the same holds on any repository. An id the issue's own text writes is refused (#2035);
  `requirements.json` records those ids under `issue_ids`, so design refuses them as SPEC ids without reading
  the issue again.
- **§1: an id never moves.** A kept requirement keeps its id. A new one's number is one more than the highest
  its code has ever had, removed ids counted — never a gap a removed one left, and never one that skips a
  number. A REMOVED line names an id the last list had (`ID_REMOVED_UNKNOWN`). A dropped requirement is
  answered `REMOVED: <id> — <why>`; `requirements.json` keeps it under `removed` (id, words, reason), carried
  from run to run, so no later list uses it again. The rules are `scripts/lib/item-ids.sh`'s, checked by the
  engine; a reply that breaks one is asked again once with what was wrong (ADR-060 §6), then is `unusable`.
- **§1: one pool.** A requirement's code is never a SPEC's (ADR-069 §1, amended 2026-11-03).
- **§2: the last list is shown with its ids, in the form the reply is written in,** with the ids already
  removed; an old position id (R-n) is shown without it, so that requirement gets an id that describes it, and
  needs no REMOVED line.
- **§2: the last list stays on disk until this run's replaces it.** A try that fails leaves it for the next
  try; a pass that writes no list (a goal run) removes it, so it is never read as this run's.
- **§2: intake says what changed by id.** `requirements_changed.added` lists `{id, text}`, `.removed` lists
  `{id, text, reason}`; the summary names each, with the reason.

## Amendment 2026-11-06 (#2477) — §1 §2: the list is kept while nothing it is written from changed

intake asked its model to read the issue on every run. On #1805 run 42127743259 it added a requirement to an
issue nobody had changed, and design lost a try renaming a SPEC for it.

- **§1: the list records what it was written from.** `requirements.json` carries `input_fp`, the fingerprint
  (`judge_fp_v`) of the engine (`judge_engine_v`), the issue as the calls are shown it (title and body), and
  intake's own instructions as written (`_ireq_write_own`, `_ireq_check_own`, `_ireq_limits`). Comments are
  not in it: the list never reads them (§1).
- **§2: an unchanged list is kept, with no model call.** When the last list's `input_fp` is this run's,
  intake keeps that list as it is, makes neither call, emits `intake.requirements.kept`, reports nothing added
  or removed, and its summary says the issue is unchanged and its requirements were kept. A list with no
  `input_fp`, a change to the issue's words, to intake's instructions, or another engine, writes it again.

## Amendment 2026-11-06 (#2476) — §1: intake keeps the one pool of ids, and a note about the work is not a requirement

#2462 made a requirement's code never a SPEC's, but only design's check held the rule. On #1805 run
42127743259 intake added a requirement DISP-1 while design's SPEC DISP-1 existed, so design had to rename a
SPEC that had not changed (DISP-1 to DSPK-1), breaking "ids never move", and its first try failed for it. The
same run listed the issue's "Order: do not run this in parallel with #1714" as ORDE-1, which no code or test
can show, so it stayed UNSURE in every round.

- **A new id never takes the other pool's code; a kept id stays.** Intake reads the codes the last design's
  SPECs use, removed ones counted (`_ireq_design_codes_v`, finding the design by its acceptance block), and
  refuses a NEW requirement with one through its re-ask. Design refuses a NEW SPEC with a requirement's code.
  An id the last list already had is never held to it: the side that just took the code is the one that
  changes. One rule set for both (`zb_ids_check_v`, `zb_id_codes_v` in `scripts/lib/item-ids.sh`).
- **A note about how or when to do the work is not a requirement.** The writing call is told so: the order to
  do it in, what not to run it alongside, when to start it. The check call may answer
  `NOT-A-REQUIREMENT: <id> — <why>` for a listed item; it leaves the list and is kept as removed with its words
  and the reason, so it never comes back. One for an id the list does not have is asked again.

## Amendment 2026-11-06 (#2480) — §1: intake says which codes it held the one pool to

On #1805 run 42229975998 no requirement took a SPEC's code, but nothing showed whether intake had read the last design's codes at all. Intake now leaves `intake.requirements.design_codes` each time it writes its list, with `codes=` the codes it read and `design=` the file it read them from, both empty when there was no design.

## Amendment 2026-11-06 (#2482) — §1: every requirement id starts with intake's prefix

- Every requirement id starts with intake's `id_prefix` (`RQ`, ADR-001): `RQLOOP-1`. intake's calls are given the prefix from its manifest. A reply whose id lacks it is asked again with a plain sentence naming the prefix (ADR-060 §6).
- A requirement and a SPEC can no longer have the same id. So intake no longer reads the last design's SPEC codes, and its `intake.requirements.design_codes` event (#2480) is gone. Amendments #2476 and #2480 above are replaced by this one as far as the one pool goes. Their rule on notes about the work stands.
- An id in the last list without the prefix is the old numbering, like `R-n`. It is shown to the call without its id, gets a new one, and needs no REMOVED line.

## Amendment 2026-11-07 — §1: a requirement names the issue's items by their ids; §4: the design check is shown the issue

On #1805 run 42340358110 one requirement read "Tests for R1–R5 must use a cycle", in the issue's words. R1–R5
are the issue's own names for its items, and no later stage is shown which items they name. Design's coverage
check was told the issue was "under Previous work", where it was not. It took R1–R5 for `RQRES-1`…`RQRES-5`,
the ids that looked like them, and refused a SPEC that covered R3 and R4. Design lost its last try to it.

- **§1: an issue's name for its items becomes the ids.** A requirement that refers to another of the issue's
  items by the issue's own name for it (R1, R1–R5) is written with the ids of the requirements it means. The
  issue's names are read from the issue: a line that starts, after any bullet, number or heading mark and any
  bold, with one to three capital letters and a number, then a stop (`- **R1.** …`). A requirement whose words
  write one is asked again, once, naming it (ADR-060 §6). A word the issue does not use as a name, such as S3,
  is not one.
- **§4: the design check is shown the issue.** As §4 says, it judges the list beside the issue's own words. They
  are found among the stage's inputs by what they are (`earlier_issue_text`, ADR-055 §1). It is shown them
  only when it judges the requirements; with no issue, its prompt claims none.

## Amendment 2026-11-08 (#2495) — §4: the check looks both ways through the SPECs only

On #1805 run 42439063480 design's first try ($2.26, 8 minutes) failed on a scope line whose own reason said the
entry "raises no concern". #2491 gave each scope entry a verdict word, but the judging itself costs more than it
finds.

- **The scope is a prediction** (ADR-030): it is written before any code exists, and build may widen it.
- **A design that goes beyond the issue does so in a SPEC,** and every SPEC is already judged `outside` when the
  issue does not ask for it. So the check is no longer shown the scope to judge, and answers no line for it; a
  `SCOPE:` line in its reply is ignored. *(#2508: design no longer writes a scope block, and C1 is gone — see
  below.)*

## Amendment 2026-11-09 (#2508) — §4: no scope block; the change is held to the requirements after it is made

Design writes no scope block and names no test file (ADR-069 §11, ADR-030 §8): a list written before any code exists was wrong often enough to end runs. The other direction of §4 — something the change does that the issue does not ask for — is now judged on the change itself: issue-acceptance names each part of the change no requirement asks for, as a finding for build (ADR-072 §3). A requirement design does not understand is written as an `UNCLEAR:` line with the assumption it went on with (ADR-069 §12), so the requirement list stays the one list every stage reads, and its open questions are shown to the people who can answer them.

## Amendment 2026-11-12 (#2527) — §1: the check sees what was removed; §4: a quote may be the issue's words

On #1805 run 43130129438 two answers that were right were lost to what the checks were shown and held to.

- **§1: intake's check is shown each removed item with its words and why it was removed,** not only its id, and told that an item already removed needs no line. It was shown only the ids, so it did not see that the note "tests must use a cycle" was already removed; it named the note again under a new id, `RQTEST-2`.
- **§1: a `NOT-A-REQUIREMENT:` line for an id the list does not have is asked again with "that is not in the list, so leave that line out"** — never "name only a listed id". Told to name a listed id, the check named `RQRESU-4`, a requirement the issue states, and it left the list.
- **§4: design's coverage check's quote for an uncovered requirement may be the requirement's words or the issue's,** as issue-acceptance's already may (§4). The check is shown both; it quoted the issue's "(an automatic resume does not count)", which intake had left out of RQFROM-4, and its answer — that no SPEC covered the case — was thrown away.

## Amendment 2026-11-15 (#2550) — §1: a limit keeps its "Do not"

On #1764 run 43735596812 the issue said "Do not build: a check of a CI job's status through the GitHub Actions API; a 'do I still hold the claim' check before each stage". Intake's check found both, but the list stored them as "a check of a CI job's status …" — a thing to build — and design, which never reads the issue, built both.

- **§1: an item the issue says not to do or not to build is a limit**, written `LIMIT: <id> Do not …` by either intake call and kept in the list with `limit: true`. Its words start with "Do not", "Don't" or "Never"; a LIMIT line that does not is asked again. A limit takes an id like a requirement, and is kept, removed and numbered the same way.
- **§1: a limit is not a requirement.** `acceptance_requirements_list` leaves it out; `acceptance_limits_list` lists the limits. Design is shown them as what the change must not do (ADR-069); issue-acceptance judges each against the change (ADR-072 §3).
- **§1: a limit stays a limit.** The check may not drop one as `NOT-A-REQUIREMENT` (that line is refused and asked again), and an id keeps its kind from the last list: a limit written back as a `REQUIREMENT:`, or a requirement as a `LIMIT:`, is asked again (lens review on #2550).
- **§1: intake's summary counts and lists the limits apart** from the requirements. An answer that still breaks a rule after it is asked again ends intake naming that rule.
- **§1: intake's prompts give each code's highest number** from the function its id check uses (`zb_ids_highest_line_v`, `scripts/lib/item-ids.sh`), and state no rule of their own (ADR-069 §1).

## Amendment 2026-11-16 (#2555) — §1: an issue's terms travel with its requirements, word for word

On #1764 run 43772987273 the issue said "that run's progress comment (ADR-064)". Intake's requirement kept "the run's progress comment" and dropped "(ADR-064)", which said which comment. Design, which never sees the issue, defined it as a new comment, and the coverage check, with only design's definition before it, answered "covered" on every try.

- **§1: intake copies the issue's `## Terms` section word for word** into its list, as `terms`, with no model (`_ireq_terms_v`, `plugins/agent/intake/lib/requirements.sh`): the lines under a `## Terms` or `### Terms` heading (any case, a colon allowed), up to the next heading. A heading inside a code fence is text, and a CRLF body's carriage returns are dropped. An issue with none has no `terms`. A list kept from an earlier run gets the terms of the issue as it is now.
- **§1: every stage that is shown the requirements is shown the terms** (`acceptance_terms_v`, which forks nothing for a list without terms): design, its coverage check, test-author and issue-acceptance. Design is told to use each term as the issue defines it; the coverage check is told that a SPEC using a term differently from its definition contradicts it.

## Amendment 2026-11-20 (#2569) — §1: a missing requirement is the issue's own sentences; §2: the last list is a starting point

On #1764 run 44530053809 intake's writing call, told to start from its last list, copied its 19 old requirements and missed the new R6. The check caught R6, but wrote it as four paraphrased pieces ("The coordinator's claim hook adds the `zbuild:claimed` label", …), and none kept R6's main point: the engine claims and releases only through the claim coordinator's hooks, called through the plugin registry. Nothing checked the rule that a missing requirement is written in the issue's words.

- **§1: a `MISSING:` line is the issue's own sentences, copied as written** — the whole sentence or item, never a paraphrase and never a part of a sentence. Spacing and the marks the judges' quote check sets aside (`*`, `_`, backticks, quote marks, `_judge_marks_v`, ADR-072 §3) do not count, nor do commas and semicolons, nor a stop at the end. A paragraph's lines are one text: a sentence the issue hard-wraps is one sentence, and only a blank line, a list mark, a heading, a table row or a code fence ends a unit. A list item's sentence starts after its bullet, checkbox, number and the issue's own label (`- **R6.** `); its continuation lines and its sub-bullets are part of the item, so the item with its sub-points, written with or without their marks, is whole, and its lead-in alone is a part. A line that writes the list's ids where the issue names its own items (as the check is told to) is still whole sentences of one item in order: each id and each issue label (`R6`, `R1–R5`) reads as one placeholder, and ids joined by "and", "or", "to" or a dash as one. The issue is made ready for the comparison once a call, not once a line (`_ireq_issue_norm_v`, `_ireq_in_norm`, `plugins/agent/intake/lib/missing-quote.sh`; #2569 review: a 195 KB issue took 5 s a line, a 1 MiB one 171 s). A line that is not the issue's words is refused and asked again once, saying so, as intake's other answers are. Still not, it does not stop the run: it is kept as the check wrote it, and intake's result names it — `data.notes` and its summary: "<id> is not in the issue's words: "<text>" — kept as the check wrote it". A `LIMIT:` line is not held to it: its "Do not" may be intake's.
- **§2 (amends #2460): the last list is a starting point, not the whole issue.** The writing call is told to read the whole issue for every requirement it states, and add each one the old list does not have.

## Amendment 2026-11-20 (#2571) — §1: what intake finds unclear is asked, and judged each try

Intake paraphrased an unclear requirement silently: nobody could see which reading the list went on with, and nothing asked again whether the issue had since settled it. Intake reads the issue directly, so it asks the issue's owner as design does (ADR-069 §12, amended 2026-11-20).

- **§1: the writing call may raise a question in the one form,** `UNCLEAR <id> | "<the issue's words>" | <the readings> | ASSUMED: <the reading chosen>`, told the shared rule (`ZB_UNCLEAR_RULES`); the requirement is still written in the issue's own words. Each line is held to the form against the issue by the shared validator (`zb_unclear_check_v`): a line with no assumption, missing its quote or readings, or quoting words that are not the issue's is asked again with intake's re-ask, saying what is wrong. Still bad after the re-ask, it is left out and intake's result notes it; the run goes on.
- **§1: intake's questions live in its result,** `data.unclear` (`zb_unclear_result_json_v`), and so reach the run report, the run-status comment and the PR description. A try that ends before its check judged them (a failed call) keeps the questions it carried, so the next try still has them, and so does a pass that writes no requirement list (the issue could not be read and a placeholder goal is allowed, a goal given instead of an issue, a list that could not be written): its check never judged them. An unchanged issue asks no model and keeps them as they are.
- **§1: intake's check judges every question intake carried** from its last result, in the same missing-requirements call, shown through the shared block (`zb_unclear_judge_block_v`) and read by the shared reader (`zb_unclear_answers_v`): `answered` (the issue's words quoted, checked against the issue) or `not needed` drops it, and intake's result records it as every stage records a question it retires — `data.unclear_dropped`, its id, how it was retired, its WHY, its QUOTE and the question (`zb_unclear_dropped_json_v`), so the reports show it as retired; `open` keeps it. A question with no usable answer is asked again with the check's re-ask, naming it; still none, it is kept, never lost. Only intake's own check retires intake's question; a new question with the id of a carried one is not added twice.

## Enforced by

- §1 amendment 2026-11-20 (#2571: intake's questions) → `tests/unit/intake-unclear-test.sh` IU1 (the writing call is told the form and the rule), IU2 (a good question in data.unclear), IU3 (no ASSUMED, or a quote not in the issue, asked again, saying so), IU4 (still bad: left out, noted, the run goes on), IU5 (the check is shown each carried question and the answer forms), IU6 (answered: dropped, recorded in data.unclear_dropped with its WHY, QUOTE and question, not again in the notes), IU7 (open kept; not needed dropped and recorded), IU8 (no answer: asked again, naming it; still none: kept), IU9 (an answer's quote not in the issue: asked again), IU10 (an unchanged issue keeps them with no call), IU11 (a failed try keeps them), IU12 (a pass that writes no list keeps them)

- §1 §2 amendment 2026-11-20 (#2569: a missing requirement is the issue's own sentences; the last list is a starting point) → `tests/unit/intake-missing-quote-test.sh` M1 (a paraphrase is asked again once, saying so; the whole R6 then passes), M2 (R6 whole, marks dropped, passes first time), M3 (a part of a sentence is refused; one whole sentence passes), M4 (a paraphrase twice is kept and named in intake's result and summary, and the run goes on), M5 (the list's ids for the issue's item names), M6 (a limit is not held to it), M7 (the check is told what the issue's words are), M8 (a hard-wrapped sentence is one sentence), M9 (an item's sub-bullets are part of it), M10 (#1764's R6, hard-wrapped, passes first time), M11 (the words between ids are whole sentences of one item, in order), M12 (the issue is made ready once a call), M13 (the review's cases); `tests/unit/intake-previous-list-test.sh` P1 (a starting point, not the whole issue)

- §1 amendment 2026-11-16 (#2555: an issue's terms travel word for word) → `tests/unit/issue-terms-test.sh` TM1 (copied word for word, no model), TM2 (none without a section), TM3 (a kept list gets them; the reader), TM4 (design's prompt), TM5 (the coverage check, and contradicts for a term used differently), TM6 (test-author's and issue-acceptance's prompts), TM7 (CRLF, a `#` line in a fence, `## Terms:`, `## TERMS`, a heading inside a fence)

- §1 amendment 2026-11-15 (#2550: a limit keeps its "Do not"; the lists; intake's numbers from its check's count) → `tests/unit/limits-test.sh` LM1–LM4, LM9, LM10, LM12; `tests/unit/ids-one-rule-test.sh` N1, N5; `tests/unit/intake-requirements-model-test.sh` I8

- Amendment 2026-11-09 (#2508) §4 → `tests/unit/design-names-no-files-test.sh` N1, N8 (no scope block is asked for or required), N9–N10 (UNCLEAR lines); `tests/unit/issue-acceptance-unasked-test.sh` U1–U4 (the change is held to the requirements)
- Amendment 2026-11-08 (#2495) §4 → `tests/unit/design-coverage-test.sh` NS1 (the prompt asks for no scope verdict), NS2 (a reply with no scope lines is complete, in one call), NS3 (a scope line is no finding), X3 (the scope is not shown to judge)

- Amendment 2026-11-07 §1 → `tests/unit/intake-stable-ids-test.sh` S13 (a requirement writing the issue's name R1 or R2 is asked again, naming each; a word the issue does not use as a name is not refused; the list is written with the ids); §4 → `tests/unit/design-coverage-test.sh` I1 (the prompt carries the issue's own words, found among the inputs; with no issue it claims none)

- Amendment 2026-11-06 (#2482) §1 → `tests/unit/intake-stable-ids-test.sh` S12 (an id without RQ is asked again, naming the prefix; the call is told it; a requirement may share a SPEC's code; a last-list id from before the prefix is shown without it and needs no REMOVED line)

- §1 amendment 2026-11-06 (#2480: intake says which codes it held the one pool to) → replaced by #2482: the event is gone, enforced by `tests/unit/intake-stable-ids-test.sh` S12

- §1 §2 amendment 2026-11-06 (#2477: the list is kept while nothing it is written from changed) → `tests/unit/intake-kept-list-test.sh` K1–K6
- §1 amendment 2026-11-06 (#2476: one pool, held by intake too — replaced by #2482's prefixes; a note about the work is not a requirement) → `tests/unit/intake-stable-ids-test.sh` S12; `tests/unit/design-stable-ids-test.sh` D6; `tests/unit/intake-process-notes-test.sh` P1–P4
- §1 §2 amendment 2026-11-03 (#2462: ids describe their requirement and never move; a removal says why) → `tests/unit/intake-stable-ids-test.sh` S1–S11; `tests/unit/intake-requirements-model-test.sh` I1, I2; `tests/unit/intake-previous-list-test.sh` P2
- §1 §2 amendment 2026-11-02 (#2460: intake starts from its last list and says what changed; one item per line) → `tests/unit/intake-previous-list-test.sh` P1–P4; `tests/unit/reply-multiline-test.sh` Q1
- §1 amendment 2026-11-01 (#2448: intake's calls have no tools) → `tests/unit/intake-no-tools-test.sh` T4
- §1 amendment 2026-11-01 (#2445: a model writes and checks the list) → `tests/unit/intake-requirements-model-test.sh` I1–I7; `tests/unit/requirements-list-test.sh` Q1
- §4 amendment 2026-11-01 (#2445: the check looks both ways; [done] evidence shown — scope judging removed by #2495) → `tests/unit/design-coverage-test.sh` X1, X2, X4, X5

- §1 → `tests/unit/requirements-list-test.sh` Q1 (sequential ids, assigned by the engine; words kept)
- §2 → `tests/unit/requirements-list-test.sh` Q1 (the manifests declare the output and the four inputs; a goal run leaves no list)
- §3 → `tests/unit/requirements-list-test.sh` Q2 (covers split from the text and evidence, either order), Q3 (an uncovered R fails, named with its words; all covered — one by `[done]` — passes; no list skips), Q4 (the design prompt shows the list and the covers syntax)
- §4 → `tests/unit/requirements-list-test.sh` Q5 (spec-coverage prompt), Q6 (issue-acceptance prompt)
- Amendment 2026-11-12 §1 (#2527: removed items shown with their words; no "name a listed id") → `tests/unit/intake-process-notes-test.sh` P5, P6
- Amendment 2026-11-12 §4 (#2527: an uncovered quote may be the issue's words) → `tests/unit/design-coverage-test.sh` I2
