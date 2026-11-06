# ADR-070 — One fixed list of requirements per issue

**Status:** Accepted (2026-10-05)
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

## Enforced by

- §1 amendment 2026-11-06 (#2480: intake says which codes it held the one pool to) → `tests/unit/intake-stable-ids-test.sh` S13

- §1 §2 amendment 2026-11-06 (#2477: the list is kept while nothing it is written from changed) → `tests/unit/intake-kept-list-test.sh` K1–K6
- §1 amendment 2026-11-06 (#2476: one pool, held by intake too; a note about the work is not a requirement) → `tests/unit/intake-stable-ids-test.sh` S12; `tests/unit/design-stable-ids-test.sh` D6; `tests/unit/intake-process-notes-test.sh` P1–P4
- §1 §2 amendment 2026-11-03 (#2462: ids describe their requirement and never move; a removal says why) → `tests/unit/intake-stable-ids-test.sh` S1–S11; `tests/unit/intake-requirements-model-test.sh` I1, I2; `tests/unit/intake-previous-list-test.sh` P2
- §1 §2 amendment 2026-11-02 (#2460: intake starts from its last list and says what changed; one item per line) → `tests/unit/intake-previous-list-test.sh` P1–P4; `tests/unit/reply-multiline-test.sh` Q1
- §1 amendment 2026-11-01 (#2448: intake's calls have no tools) → `tests/unit/intake-no-tools-test.sh` T4
- §1 amendment 2026-11-01 (#2445: a model writes and checks the list) → `tests/unit/intake-requirements-model-test.sh` I1–I7; `tests/unit/requirements-list-test.sh` Q1
- §4 amendment 2026-11-01 (#2445: the check looks both ways; scope and [done] evidence shown) → `tests/unit/design-coverage-test.sh` X1–X5

- §1 → `tests/unit/requirements-list-test.sh` Q1 (sequential ids, assigned by the engine; words kept)
- §2 → `tests/unit/requirements-list-test.sh` Q1 (the manifests declare the output and the four inputs; a goal run leaves no list)
- §3 → `tests/unit/requirements-list-test.sh` Q2 (covers split from the text and evidence, either order), Q3 (an uncovered R fails, named with its words; all covered — one by `[done]` — passes; no list skips), Q4 (the design prompt shows the list and the covers syntax)
- §4 → `tests/unit/requirements-list-test.sh` Q5 (spec-coverage prompt), Q6 (issue-acceptance prompt)
