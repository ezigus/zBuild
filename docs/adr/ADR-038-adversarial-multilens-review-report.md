# ADR-038 — Adversarial multi-lens review report (evidence-fed, advisory)

**Status:** Accepted (2026-06-19); amended 2026-11-26 (#2630: a suspicion sends the change round once a run — ADR-040 §3); amended 2026-11-22 (#2584: a lens reviews the whole change fresh every round; a finding names every place with the same kind of problem; inputs whole, never cut; a suspicion is a question; outside assumptions are checked, with a read-only GitHub lookup); amended 2026-11-09 (#2508: no planned scope is shown to a lens — design writes none); amended 2026-11-15 (#2548: each lens has its own job text; the persona is who does it); amended 2026-11-20 (#2574: a lens keeps its verdict per file of the change; its findings have ids; an answer no longer in its fingerprint); amended 2026-11-20 (#2571: an unclear issue is a question in the one form, not `fix: issue`; a lens judges the questions it carried); amended 2026-11-15 (#2552: every finding names its trigger; a check call tries to knock each lens's findings down); amended 2026-11-20 (#2569: every finding says what would be accepted; a lens is held to its earlier findings); amended 2026-11-20 (#2569: a finding's fix: word is its topic)
**Related** — dispositions below are **PLANNED** (the map lives in ADR-037 §6, executed in I13 / #979); **this PR edits no existing ADR**:
- peer: ADR-037 (objective gates vs. semantic judgment); EPIC #966
- supersede-planned: ADR-022, ADR-026
- amend-planned: ADR-019, ADR-036, ADR-030 (R3 assertion-integrity folded into a review lens)
**Issue:** #967 (EPIC #966, I1)

## Context

ADR-037 routes all semantic judgment to a single advisory stage. This ADR defines that stage.

The trap to avoid is documented by the system it replaces: `cq-cycle` is a 7-lens audit loop and it
catches **nothing** (it writes `"findings":[]`). Adding lenses to a hollow loop produced zero teeth,
because every lens read the *same* diff and asked "is this good?" in a different voice — they correlate
and miss the same blind spots. The adversarial-critique analysis was blunt: "diverse *questions over
identical evidence* is the cq-cycle trap," and a review that doesn't change a decision is inert by
construction.

So the burden on this stage is to be **structurally** different from the single review and from
cq-cycle, not merely "more lenses."

## Decision

Collapse all semantic judgment — the former `review` verdict, `test_assessment`'s LLM grading, the
cq-cycle lens loop, the `impact` adversarial consequence-finding, and ADR-030's assertion-integrity
charter — into ONE `review` stage that runs **after** the objective gates (ADR-037) pass.

### 1. Single pass, parallel lens fan-out

One stage, no remediation cycle. The lenses run concurrently in a single pass; there is no loop that
exists to make the report turn green (that loop — ADR-026 review-remediation — is removed). Findings may
optionally seed ONE bounded build retry, but the report is advisory and is not a convergence predicate.

### 2. Each lens is fed DISTINCT mechanical evidence

This is the structural difference from cq-cycle. A lens receives a *different artifact*, not just a
different prompt over the same diff:

- "wired into the live path?" ← the reachability-ablation result (ADR-037 objective layer)
- "is the risky code tested?" ← the coverage map + `negctl` baseline-fail output
- "did build honor the design?" ← the `design.md` decisions (the #919 surface)
- "is the change complete / consistent?" ← the call graph / changed-symbol closure

A lens whose evidence is unavailable says so in the report rather than guessing.

**Change-bundle basis (#896/#952).** When a lens has no distinct per-lens artifact it falls back to the
shared "change bundle". That bundle is the **full-branch merge-base diff** — `git diff <merge-base> HEAD`
resolved via the shared `zbuild_resolve_merge_base` (`scripts/lib/merge-base.sh`) — NOT the per-run
incremental build `diff.patch`. *(Amended by #1655: the candidates were `origin/main → main → HEAD~1`;
the trunk is now resolved rather than assumed, and the `HEAD~1` guess is gone — an unresolvable baseline
returns empty and falls through to the `diff.patch` step of the chain below.)* The incremental diff is
EMPTY on a resumed/green run or when the work was committed before intake, which silently starved every
lens of evidence (the observed #952 failure where all lenses hit the C6 redaction precondition on empty
input). `review`, `review-lens` and `review-report` all resolve this ONE basis through
`zbuild_change_bundle`, so the operator banner, the `review` verdict, and the advisory lenses judge the
same change set. Fallback chain (fail-soft, never crashes): merge-base diff → build `diff.patch` →
"(no change bundle available)" sentinel.

### 3. Output is a report, never a gate

The stage emits a structured **merge-readiness report** (findings + severities + rationale), aggregated
and de-duped (file + category + proximity). It **never hard-blocks merge and never coerces a verdict**
(no `approve`/`request_changes`/`block` mutation). Per ADR-037's invariant, no semantic lens hard-blocks
merge. Escalation to a human PR is decided by ADR-037's `merge_policy` from the report's top-severity
findings / lens disagreement — the report is the *input* to that policy, not a gate itself.

### 4. Lenses are the rehomed cq + persona content

The lenses are the existing cq audit lenses (security / logic / integration / completeness /
error-handling / performance / edge-case) and the persona plugins (architecture-enforcer, red-team,
developer-sim, …), plus design-decision-honoring and assertion-integrity (folded from ADR-030 R3). The
inert cq-cycle / cq-audit-plan / cq-backtrack orchestration is retired (ADR-037 §6 / I13); the lens
*content* is preserved.

## Consequences

- The single point of semantic failure (one fallible review verdict that could be smuggled past or could
  coerce) is replaced by diverse, evidence-fed judgment whose output informs — but does not forge — the
  merge decision.
- Because each lens consumes mechanically-derived evidence, the "wired-in?" and "tested?" questions are
  backed by the objective layer's deterministic results, not by an LLM re-reading the diff — closing the
  gap that made cq-cycle inert.
- `test_assessment` as an LLM grader is no longer needed (build/test convergence uses objective
  suite-green per ADR-037); the review-remediation cycle (ADR-026) is removed.

## Implementation Notes (EPIC #966)

Delivered by the Group-2 sub-issues of EPIC #966:

- **#972** — the review stage: single pass, parallel lens fan-out, emits the merge-readiness report;
  no merge coupling, no coercion.
- **#973** — evidence plumbing: feed each lens its distinct mechanical evidence (reachability result,
  coverage map, `negctl` baseline-fail output, `design.md` decisions per #919, call graph).
- **#974** — rehome the cq audit + persona lenses into the fan-out; aggregate + dedup the report.

Escalation wiring to `merge_policy` lands with #975; the retirement of `test_assessment` / cq-* / the
review-remediation cycle lands with #976 / #979 per ADR-037 §6.

## Limitations / future work

- "More lenses" only helps if the evidence is genuinely diverse (§2); adding a lens that reads only the
  diff re-creates the cq-cycle trap. New lenses must declare their evidence input.
- The report changes a decision only via `merge_policy` (ADR-037) and the human; if a template runs
  `merge_policy: auto`, the report is purely informational — acceptable, but it then catches nothing on
  its own (by design, the objective gates are the floor).
- Per-lens model/tier selection and cost bounds are out of scope here (router config, ADR-017).

## Amendment (Issue OUT — merge-readiness report surfaced to the operator)

The aggregated merge-readiness report is now surfaced to the operator as
human-readable PROSE, not just written to disk. After `review-aggregator` writes
`review-report.json` + `review-report.md` (rendered by `render_review_report_md`),
it prints the already-rendered `.md` to `fd ${ZBUILD_STAGE_IO_FD:-2}`, gated on
the stage's own `io:` destinations (`template_stage_io_dests`): a file-only
install stays silent; a stdout install shows the full readiness header, summary,
and per-lens / de-duped findings. Because the lens members are file-only
(ADR-015 / ADR-039), this aggregator prose — together with the per-member
one-liners — is the operator's human-readable review surface; the raw lens and
report JSON remain in artifacts. Guarded by `tests/unit/review-aggregator-test.sh`
(io-gated print, both directions) and `tests/integration/review-lenses-output-test.sh`.

## Amendment (2026-09-28): a lens judges with context, and says what is new

**Evidence.** #1845's PR #2213: six lenses, 22 findings, 0 critical/high. They
missed the two real defects — a path the plugin built itself (the issue forbade
it) and 26 assertion tags stripped from a shared test — and raised false ones:
engine-set `ZBUILD_*` values read as attacker input, a test's hand-wiring read
as the production path, unchanged behaviour (`ZBUILD_DRY_RUN` trust) blamed on
the change, and every planned file the change did not touch. Each lens saw only
the diff and was told "report only issues you can point to in the change below"
(#1654).

**Decision.** Still one isolated call per lens (§2); what it is given changes.
1. **What the change was for.** The prompt carries the issue text, the design's
   acceptance contract (SPECs) and the planned scope — optional name-matched
   inputs (`intake_goal`, `design`) resolved by the engine.
2. **Read around the change.** The diff shows what changed; the lens is told to
   read the rest of the file, callers, input producers and comparable code, and
   may cite unchanged code as evidence (#1654).
3. **New or pre-existing.** Each finding carries `introduced`. The aggregator
   counts only introduced findings toward merge readiness and lists the rest
   under `pre_existing`; a finding that does not say is counted.
4. **The repository's rules, as a reviewer.** the repository's rules
   reach every lens under From the repo (since 2026-10-12, ADR-067 §8, ADR-032;
   previously by declaring `prompt.repo_rules`); work that breaks one is wrong, and the rules file's "Facts about this repo" section states
   what is trusted (e.g. engine-set `ZBUILD_*`).
5. **Scope lens.** Planned-but-untouched files are not findings (the plan lists
   files that might change); edits beyond what the issue asked for are.
6. **No self-echo.** A lens is no longer shown its own previous review, as no
   judging stage is (ADR-055 amendment, #2212).

#1654's live acceptance (a real lens catching a sibling-function inconsistency,
and the wall-clock before/after) is verified on the next pipeline run, not in
unit tests, which stub the model.

Verification: `plugins/agent/review-lens/tests/review-lens-context-unit-test.sh` (C1–C9).

## Amendment (2026-10-05): the planned scope is design's scope block (#2302)

**Evidence.** On #2035 every lens prompt's "THE PLANNED SCOPE" section read
`+ ./`. It was filled from the `scope_manifest` input, which is the redaction
allow-list, not the plan, so the scope lens had no file list to compare the
change against.

**Decision.** The planned scope given to a lens (item 1 of the 2026-09-28
amendment) is the files listed in the design's ```` ```scope ```` block, read
with `acceptance_list_scope` (`scripts/lib/acceptance-block.sh`), the same list
build is given. The `scope_manifest` input is not shown to a lens. A design
with no scope block gives no planned-scope section.

Verification: `plugins/agent/review-lens/tests/review-lens-context-unit-test.sh`
(C12, C3 — since #2508 they assert no planned-scope section is shown).

**Amended 2026-11-09 (#2508):** design writes no scope block (ADR-030 §8, ADR-069 §11), so a lens is shown no planned-scope section. What build changed is held to the issue by issue-acceptance's reverse question (ADR-072 §3).

## Amendment (2026-10-05): every lens compares the change with the issue (#2307)

**Evidence.** Every lens prompt carries "THE ISSUE (what was asked for)", but no
charter asked whether the change delivers it: `scope` looks only for over-reach,
`correctness` and `red-team` look at logic and attacks, and `design-conformance`
is not in the default template and compares against the design. No lens flagged
that PR #2298 skipped the loop expansion, the red step and the negative control
its issue asked for.

**Decision.** Every lens compares the change with the issue and names any part
of the issue the change does not deliver, in its own terms, as a finding. The
instruction is written once, in the prompt builder (`_rl_build_lens_prompt`,
`plugins/agent/review-lens/lib/charters.sh`), so it reaches every lens whether
its charter comes from a persona manifest or the built-in fallback; no charter
repeats it. (2026-11-15, #2548: a lens's job is its own text, `lenses/<lens>.md`; the instruction is
still written once in the prompt builder, beside it.)

Verification: `plugins/agent/review-lens/tests/review-lens-context-unit-test.sh`
(C13: for each lens in `config/templates/simple.yaml`'s `review_lenses`, the
prompt the plugin sends carries the instruction).

## Amendment (2026-10-12): every lens gets the same evidence; the lens's question is its persona's (its second half withdrawn 2026-11-15, #2548)

§2's per-lens evidence is retired. Nothing produced the per-lens artifacts once review-report went (the
call graph was its own), and a lens is a stage like any other (ADR-051 §3, amended 2026-10-12): every
lens judges the same change bundle (§2's merge-base basis), the review-lens stage writes one job for every
lens, and the question each lens asks is the perspective of the persona its element names (withdrawn
2026-11-15, #2548: each lens's job is its own text — see that amendment). review-report
and `scripts/lib/call-graph.sh` are retired.

Enforced by: `tests/unit/retired-impact-review-report-inputs-test.sh` RT2 (review-report and the call
graph are gone), RT3 (one job, the same evidence, no lens text table).

## Amendment (2026-10-15, #2368) — the merged review report is retired

The lenses stay isolated stages (§2), each writing its own output, which every later stage sees. The
merge of their results into one report — `review-aggregator` and `review-report.json` — is retired: the
engine writes the lens group's summary and says whether a lens was flagged (ADR-040, #2368 part 2). The
PR body no longer carries review findings. Enforced by `tests/unit/engine-combines-map-test.sh` M1, M2
and `plugins/tool/pr-open/tests/pr-open-body-test.sh` B2.

## Amendment (2026-10-29): a lens is given the code in full and the tests by name

Every lens still gets the same evidence (amendment 2026-10-12), but no longer all of the diff: each
changed file's diff is in the prompt except the tests', which are listed with their lines added
and removed. A lens that needs a test opens it in the worktree with its own tools. Which paths
are tests is the repository's list (`.zbuild/test-paths.txt`, else the engine's; ADR-069 §10).
On #1944 the test diffs were 68 KB of a 98 KB diff, read by every lens before it could start;
five of six then ran out of time. Enforced by
`plugins/agent/review-lens/tests/review-lens-evidence-test.sh` (removed by the amendment below).

## Amendment (2026-11-09, #2507): a lens is pointed at the change, not given it

The amendment above is replaced: a lens is given no diff at all. Every lens gets the same change, named the
way ADR-072 §7 says — the commit the branch started from and each file it changed — and reads each change
with git (its tools include read-git, ADR-017 §12). Enforced by `tests/unit/judge-change-list-test.sh` L3–L5.

## Amendment (2026-10-30, #2433): one severity scale; each finding says what would fix it

Every lens grades each finding on one scale, defined once in the lens charter
(`plugins/agent/review-lens/lib/charters.sh`), which every lens receives:

- `critical`: the change makes the program unsafe or wrong for everyone: data loss, a security hole, or the run breaking on a normal path.
- `high`: the change is wrong on a path the issue cares about, or breaks something it should not touch.
- `medium`: the change works, but a realistic case gets it wrong, a test does not prove what it claims, or the design leaves a gap that will cause the next bug.
- `low`: style, wording, a small inefficiency, or hardening against an unlikely case.

Each lens gives examples of each level for that lens — in its own job text since 2026-11-15 (#2548), in
its persona before; the definitions live only in the charter.
Each finding also says what would fix it — `code`, `test`, `design`, or `issue` (the issue itself is
wrong: it contradicts an ADR or asks for something that cannot be built as written) — never which stage.
A word off that list is read as `code`. Scope is no longer warn-only: its findings send the change back
like any lens's. *Amended 2026-11-20 (#2569): the fix word is the finding's topic, untranslated — see that amendment.*

Enforced by: `plugins/agent/review-lens/tests/review-lens-loop-test.sh` R1 (the four levels and the fix
words are in every lens's prompt), R1b (each lens's job text gives an example of each level, #2548; scope is no
longer warn-only); `plugins/agent/review-lens/tests/review-lens-test.sh` #1140-12.

## Amendment (2026-11-15, #2548): each lens has its own job; the persona is who does it

The 2026-10-12 amendment made "the question each lens asks … the perspective of the persona its element
names", and that sentence is withdrawn. A persona is a role and its mindset, reusable for any work
(ADR-051 §9, amended 2026-11-15), so a lens's job cannot live in it: five lens personas began
"Examine the change …" with severity examples, and `scope` and `correctness` were lens jobs with a
role's name. On #1700 run 43663836927, 10 of 15 lens findings had a real quote but a case that cannot
happen, and only the scope lens said what is not a finding.

- **Each lens's job is its own text**, kept by the review-lens stage at
  `plugins/agent/review-lens/lenses/<lens>.md` and put in its prompt's `## What you own`. It says what
  the lens looks for, what is **not** a finding for it, where its problems come from on a real run, and
  an example of each severity level. The levels themselves are still defined once, for every lens
  (2026-10-30 amendment).
- **The template names the lens and, separately, the persona it runs as** (ADR-051 §2). The correctness
  lens runs as `test-strategist` and the scope lens as `product-owner`.
- **A lens with no job text reviews nothing**: it ends `misconfigured`, and no model is asked. A lens's
  job is the install's only: a repository's template naming a lens zbuild does not ship ends there. (A
  repository's own lens jobs were considered and left out: read from the worktree, a run's own change
  could rewrite the lenses that judge it.)
- Every lens still gets the same evidence, and the review-lens stage special-cases no lens in code.

Enforced by: `tests/unit/lens-task-test.sh` L1 (every template lens has its job, with its four parts),
L2 (a lens's prompt holds its own job; two lenses' prompts differ by more than their names), L3 (a lens
with no job ends misconfigured, no model asked), L4 (correctness runs as test-strategist, scope as
product-owner), L5 (the unused `security-lens` plugin is gone, the security lens stays);
`tests/unit/retired-impact-review-report-inputs-test.sh` RT3 (the job is the lens's own text, not its
persona's); `plugins/agent/review-lens/tests/review-lens-loop-test.sh` R1b (each lens's job gives an
example of each level); `plugins/agent/review-lens/tests/review-lens-test.sh` #1140-11, #1140-12.

## Amendment (2026-11-15, #2552): every finding names its trigger; a check tries to knock it down

On #1700 run 43663836927, 10 of 15 lens findings quoted a real line but described a case that cannot happen ("if the load guard is pre-set…", "a vendor-patched stat…"). The quote check (ADR-072 §3) proves the line exists, not the claim; nothing asked what makes the problem happen, and only the lens judged its own findings.

- **Every finding names its `trigger`:** what makes it happen on a real run, as the lens's "Where these problems come from" says. A finding with none makes the reply unusable, asked again once, as a finding with no quote does. The finding a stage is sent shows it ("happens when: …").
- **A check call tries to knock each lens's findings down.** In the lens's own stage, a second call (`check`, run as `quality-assurance`, ADR-051 §5) is shown only the findings — file, severity, message, trigger, quote — never the lens's reasoning. It answers each `<n>: stands`, or `<n>: knocked down | WHY | QUOTE: <file> | <line>` with the code that shows it cannot happen. A knock-down whose quote is a whole line of the file it names, and does not overlap the finding's own quote, moves the finding to the lens result's `knocked_down`; it reaches no stage and does not count toward the lens's outcome, and the lens's summary names it with why, so a person sees what no stage is sent. Any other knock-down — a quote not there, a fragment of a line, or the finding's own line — leaves it standing. A trigger that is filler ("unknown", "n/a") is no trigger. The check runs inside the lens's signal guard: cut short by a signal or its turn limit, the lens ends `interrupted` or `out_of_turns`, as its own call does. A lens with no findings makes no check call. An answer that cannot be used, asked again once, leaves every finding standing (`review_lens.check_unusable`, with why; the summary says so). The answer is kept while the findings and the change are unchanged (ADR-072 §4).
- **The lens is asked for "each problem in the change you can say what makes happen, and quote the code that shows it".**

Enforced by: `tests/unit/lens-check-test.sh` K1 (no trigger: asked again, then unusable), K2 (the routed finding shows its trigger), K3 (one check call, given each finding's parts; none without findings), K4 (knocked down: not routed, kept, the lens passes), K5 (a knock-down whose quote is not there: the finding stands), K6 (the check runs as quality-assurance), K7 (a kept check answer), K8 (the wording), K9–K11 (a knock-down of the finding's own line, a fragment, or a quote inside its own leaves it standing), K10 (the summary names what was knocked down), K12 (a check cut short: interrupted / out_of_turns), K13 (a filler trigger is none), K14 (a wrapped answer line is read whole), K15 (a knock-down with no quote is asked again), K16 (a finding written as a plain string is asked again).

## Amendment (2026-11-19, #2567): work asked for and not done is the change's

On #1764 run 44417314654 the scope lens found that `plugins/claim-coordinator/github-labels/plugin.sh` still used `claimed:<machine>`, which the design said to change. It marked the finding `introduced: false`, because the code before the change used it too. So the finding was listed as pre-existing and never went back to be fixed.

`introduced` (§3) also covers what the change was asked to do. Something the issue or the design asks this change to do, and the change does not do, is the change's: `introduced: true`, even where the code before the change behaved the same way. `introduced: false` is only for what the code already did when nothing asked this change to change it. Every lens is told so in its prompt (`_rl_build_lens_prompt`, `plugins/agent/review-lens/lib/charters.sh`). A design step build answered not needed, its check accepting the reason (ADR-072 §3), is not undone work: every lens is shown those answers (THE DESIGN STEPS BUILD FOUND NOT NEEDED, read from build's steps lines) and reports one only by showing its reason wrong, quoting the code. Enforced by `tests/unit/lens-task-test.sh` L6, L7.

## Amendment (2026-11-20, #2569): every finding says what would be accepted; a lens is held to its earlier findings

On #1764 run 44530053809 a check refused a step with advice the engine wrote ("make the step agree with the issue"), and design took the issue's words the wrong way. Every check's refusal now says what would be accepted, in the check's own words (ADR-072 §3, amended 2026-11-20).

- **Every lens finding carries `accepted_if`:** what must be true for it to be resolved, in the issue's words — never how to build it (no file, function, command or change to make). The lens is told so, with #1764's example: not `ACCEPTED IF: runner.sh calls plugin_hook_call on the claim-coordinator folder`; this: `ACCEPTED IF: the engine itself calls the claim coordinator's claim and release hooks through the plugin registry` (`_rl_build_lens_prompt`, `plugins/agent/review-lens/lib/charters.sh`). A finding with none, or with filler ("unknown", "n/a"), makes the reply unusable, asked again once, as one with no trigger does (`_rl_quote_problem_v`). The finding a stage is sent ends with it ("; ACCEPTED IF: …").
- **A lens is held to its earlier findings** (ADR-072 §5, amended 2026-11-20). Every answer a stage gives one of its findings — done, wrong or not mine — is in its kept report's fingerprint, and it is shown its findings from last time with every answer (`judge_last_findings_block_v`) and asked, for each answered one, whether the answer resolves it: when it does, it does not report it again; when it does not, it reports it again, saying why. The separate disputes block is gone: last time's findings carry every answer.

*Review, 2026-11-20 (#2569):* a finding with no `accepted_if` is asked again, as before, and then costs only itself: when the only thing wrong with a reply is findings with no `accepted_if`, the report without those findings is used if no reply can be used whole (`_rl_quote_problem_v` names them, `_RL_NO_ACC`). It is not kept for a later round. A lens's kept report still has every answer to its findings in its fingerprint (ADR-072 §4 §5, review).

Enforced by: `tests/unit/checks-accepted-if-test.sh` A8 (no accepted_if: asked again, then only that finding is dropped, the report's others used; the routed finding shows it; the lens is told what it says, with #1764's example, and the field is in its schema); `tests/unit/checks-held-to-findings-test.sh` H4 (every answer reaches the lens); `tests/unit/finding-answers-test.sh` A2, C3.

## Amendment (2026-11-20, #2569): a finding's fix: word is its topic

The lens code translated a finding's `fix:` word into a topic of different words: `fix: code` went to `change-findings`, `fix: test` to `code-findings`, `fix: design` to `requirement-findings` (ADR-071 §1, #2491, #2556). The topics are now named by what must change, in the lens's own words (ADR-071, amended 2026-11-20), so the table is gone.

- **A finding's `fix:` word is its topic, `<fix>-findings`, and names its output, `lens-<id>-<fix>-result.json`:** `code` → `code-findings` (build), `test` → `test-findings` (test-author), `design` → `design-findings` (design). The FIX list a lens is given is unchanged. A word off the list is still read as `code`.
- **`fix: issue` stays a run stop:** at the stage's fail rule's severity the lens's outcome is `misconfigured`; the finding is written with the design's, as before.

Enforced by: `tests/unit/topic-vocabulary-test.sh` V3 (a lens finding's fix: word names its output and is that output's topic), V4 (each reaches only the stage that can fix it); `plugins/agent/review-lens/tests/review-lens-loop-test.sh` R3 (one output per fix: word), R7 (`fix: issue` stops the run); `tests/unit/lens-check-test.sh` K17.

## Amendment (2026-11-20, #2571): an unclear issue is a question; a lens judges the questions it carried

A lens could only say the issue is wrong (`fix: issue`, which stops the run). An issue whose words could mean either of two things is not wrong. A lens reads the issue directly, so it asks the issue's owner as design does (ADR-069 §12, amended 2026-11-20).

- **A lens writes what it finds unclear in the issue in the one form,** `UNCLEAR <id> | "<the issue's words>" | <the readings> | ASSUMED: <the reading chosen>`, as a string in its report's `unclear` list — not a finding — and judges the change by the reading it assumed. It is told the shared rule (`ZB_UNCLEAR_RULES`) and that an issue that could mean either of two things is a question, never `fix: issue`.
- **An issue that is wrong stays `fix: issue`,** a run stop, as before.
- **Each question is held to the form against the issue** (`zb_unclear_check_v`), read with the formatting around it aside (a list bullet or number, bold or code marks): a line not in it is asked again with the lens's re-ask, saying what is wrong.
- **A question never costs the lens its report.** After the one re-ask, a line still not in its form is left out and a carried question with no usable answer is kept open, each named in the result's `data.notes`; the findings stand. A re-ask answered worse (no longer usable) leaves the first report, whose only problem was a question.
- **A lens's questions are in its result,** `data.unclear`, and the reports show them. A lens that ends before its call judged them (a failed call, an unusable reply) keeps those it carried.
- **A question a lens raises is never free:** it reaches design, in the lens's design-findings output (`lens-<id>-design-result.json`), as a finding that blocks nothing — "The issue is unclear here, and the <id> lens judged by the assumption: <the question>" — as issue-acceptance's questions do (ADR-072 §3). Design answers it like any finding, so a lens cannot file a question in place of a finding at no cost. One it carried is no new finding. The check call (#2552) is shown findings only, not questions.
- **The lens's next call judges every question it carried,** shown through the shared block (`zb_unclear_judge_block_v`) with its answers given in the report's `unclear_answers` list and read by the shared reader (`zb_unclear_answers_v`): `answered` (the issue's words quoted) or `not needed` drops it, recorded in the result's `data.unclear_dropped` — its id, how it was retired, its WHY, its QUOTE and the question (`zb_unclear_dropped_json_v`) — so no retirement is silent; `open` keeps it; no usable answer is asked again, naming it. The questions carried are in the kept report's fingerprint (ADR-072 §4).

Enforced by: `tests/unit/lens-unclear-test.sh` LU1 (the form, the unclear list, a question is never fix: issue), LU2 (a question: the verdict stands, data.unclear; it reaches design as a finding that blocks nothing, and no other stage), LU3 (no ASSUMED, or a quote not in the issue, asked again), LU4 (fix: issue still stops the run), LU5 (the next call is shown each carried question and the answer forms; open kept and no new finding; no answer asked again, naming it; answered dropped), LU6 (a failed call keeps them), LU7 (a bulleted question is read; still bad after the re-ask: left out, noted, the report kept; a carried question with no usable answer kept open, noted; a re-ask answered worse leaves the first report), LU8 (a retired question recorded in data.unclear_dropped with its WHY, QUOTE and question).

## Amendment (2026-11-20, #2574): a verdict per file of the change; findings with ids

A lens kept one report for the whole change, with every answer to its findings in its fingerprint (the #2569 amendment above): any change, any answer, or an answer no longer given, had it review the whole change again, where its findings flip.

- **A lens keeps a verdict per file of the change** (ADR-072 §4 §5, amended 2026-11-20). A finding names the file it is about, so each file is an item: its kept findings, or that it had none, stand while the file — and the files outside the change the call read, and those its findings quote — are unchanged. What is in no file of the change, with the score and the questions, is one more item, asked whenever the lens is called. Only the files whose report no longer holds are asked, in one call, told to review only those; a finding about another file is set aside. **An answer is no longer in the fingerprint:** it has a file reviewed again, held to its findings (last time's findings with every answer, as before), only when that file's kept report found something. This replaces "a lens's kept report still has every answer to its findings in its fingerprint".
- **Each routed finding has an id** (ADR-068 §5, amended 2026-11-20): the stage's prefix and the lens's whole name, its letters and digits in upper case (`RLSRE-1`, `RLREDTEAM-1`), so two lenses' ids are never the same, and its `area`, the file it is about. Stages answer it by that id.

- **Review, 2026-11-20 (#2574):** a file's report depends on every file the call read — the other changed files among them — and, when it found something, on every file of the change; a renamed file keeps the report of its old path (ADR-072 §4); a file a stage handed on waits for the stage it was handed to (ADR-072 §5), the summary saying so; a lens's findings' code is its whole name, so two lenses' codes are never the same; a clean file judged again because the code moved takes a finding only on a line added since (ADR-072 §4).

Enforced by: the verdict per file was retired by #2584 (below), and its tests (lens-per-item-test.sh LP1–LP9, LP11–LP14) with it; a lens's findings' code, `tests/unit/lens-fresh-test.sh` LF7; `tests/unit/finding-goes-to-fixer-test.sh` F2, `tests/unit/map-findings-reach-stages-test.sh` M1, M5 (a lens finding shown by its id).

## Amendment (2026-11-22, #2584): a lens reviews fresh, names every similar place, sees whole inputs, reports suspicions

On #1764 local reviewers found two high and five medium defects in the pipeline's change that its six lenses never reported. Run 44910536811 shows why: held passes silenced the lenses (ADR-072 §4 §5), each fix covered only the instance found, THE ISSUE and THE REQUIREMENTS were cut at 6,000 characters, red-team reasoned its way to a gap and reported nothing, and no lens could see that a label the change used did not exist.

- **A lens reviews the whole change fresh in every round.** It keeps no verdict and holds no pass (ADR-072 §4 §5, amended 2026-11-22): the #2574 amendment's verdict per file of the change, above, no longer applies. Its findings still have ids. It is still shown last round's findings with their answers.
- **A finding names every place in the change with the same kind of problem.** The lens is asked for them in the finding's `also_at` list (`<file> | <the line that shows it there>`). They reach the stage that fixes it in the routed finding's text: "the same kind of problem also at: …" Each place is held to the change as the finding's quote is (review of #2584): its line must be in its file now, in the file as it was, or in the round's patch; one that is not, or that names no line, is left out, and a note in the result says so.
- **A lens is shown its inputs whole.** The issue, the requirements, the design's decisions and the design steps build found not needed are given in full. A section over 24,000 characters (`_RL_CONTEXT_INLINE_MAX`, `plugins/agent/review-lens/lib/context.sh`) is written whole, sanitised and redacted as the prompt is (`apply_scope_redaction`), to a file of its own in the stage's scratch (`lens-<id>-context-<issue|requirements|decisions|not-needed>.md`), and the prompt gives that one path for the lens to read (review of #2584: a path to the raw file skipped both). Nothing is cut.
- **A suspected problem is reported.** What a lens suspects but cannot confirm goes in its `unclear` list as an object — file, quote, suspicion, what would confirm it (`confirm_by`) and who can answer it (`fix`: code, test or design). It reaches that stage's findings topic as a question that blocks nothing ("A question: say whether it holds, and why."), so it never sends the change back *(amended by #2630: once a run, it does)*. *(Amended 2026-11-26, #2630, ADR-040: the first time, it blocks — the change goes round once, and the stage runs what would confirm it; sent already in the run, it blocks nothing.)* It is kept in the result (`suspected`). One that says nothing would confirm it is left out, and a note in the result says so. **A suspicion left open is listed for a person** (review of #2584: in a round that otherwise passes no stage reads the question): it is in the lens's summary (`lens-<id>-summary.md`, "suspected, not confirmed: … — what would confirm it: …") and in its routed result's `data.suspected`, which the run's open questions read (`zb_unclear_markdown_v`, `scripts/lib/unclear-report.sh`) — the live status comment, the completion comment and the PR body.
- **Every assumption the change makes about something outside its own code is named and handled** — a service, a repository setting, an environment value, a data format, another program's output. Handled means the code creates it, or checks it and fails clearly (an event or a status line), or the design says why it is safe to assume. Design, build and the lenses are told the one rule (`ZB_OUTSIDE_ASSUMPTIONS_RULE`, `scripts/lib/outside-assumptions.sh`); a lens reports one not handled as a finding, and checks one about GitHub with the read-only lookup (`read-github`, ADR-017 §12, amended 2026-11-22) instead of guessing it. Design's check judges it as an item of the decisions (`Decision: unhandled`, ADR-073 §5, amended 2026-11-22), and issue-acceptance is told it beside the lookup: a requirement whose change rests on an outside assumption it does not handle is unmet (review of #2584: the rule had been prompt text only).

Enforced by: `tests/unit/lens-fresh-test.sh` LF1–LF6, LF8 (fresh every round); `plugins/agent/review-lens/tests/review-lens-asks-test.sh` S1, S2 (every place, and it reaches the fixer), S3–S5 (a suspicion — *amended by #2630: it blocks once a run, S4, S11–S15*; one with nothing to confirm it is left out, with a note), S7 (the outside-assumption rule and the lookup in the lens's prompt), S8 (a suspicion left open is in the summary and the run's open questions), S9 (each place held to the change; one not there left out, with a note); `plugins/agent/review-lens/tests/review-lens-whole-inputs-test.sh` W1–W4 (whole), W5, W6 (over the inline size: a file of the section, one path each; never cut), W7 (that file sanitised and redacted); `tests/unit/outside-assumptions-test.sh` OA1–OA4 (one rule, in design's, build's and the lens's prompts), OA5 (design's check judges it), OA6 (issue-acceptance is told it, beside the lookup); `tests/unit/read-github-tool-test.sh` RG7 (the lens's calls have the lookup).

## Amendment (2026-11-23, #2598): a lens answers in plain lines

A lens's answer is lines, as every other check's is, read by `plugins/agent/review-lens/lib/reply-lines.sh` into the object the rest of the lens uses:
- a `SCORE: <0-10>` line;
- each finding as `FINDING` and its fields, one per line: `severity`, `category`, `fix`, `introduced: yes|no`, `quote: <file> | <line>`, `message`, `trigger`, `accepted if`, and one `also at: <file> | <line>` for each other place;
- each suspicion as `SUSPICION` with `quote`, `suspicion`, `confirm by` and `fix`;
- the `UNCLEAR` lines and their answers, as in other stages.

A line with no key carries on the field above it, up to a blank line, and a list mark or bold around a key is set aside. An answer in another form, JSON included, is asked again and told the form. Lenses answered with one JSON object only for history (#767, #801). Its quotes had to escape what they quoted, and #2532 run 45231040380 was lost to one. A finding that still cannot be checked after its re-ask costs only itself (ADR-072 §3, amended).

Enforced by: `tests/unit/lens-reply-lines-test.sh` L1–L7; `plugins/agent/review-lens/tests/review-lens-unchecked-test.sh` U1–U4.

## Amendment (2026-11-24, #2603): a lens tries a new check against the forms of its problem

When a change adds a check whose job is to catch something (a guard test, a scanner, a lint), every lens lists the other ways the thing it catches could be written and tries each against the check. Each form that gets through is a finding. #2532's guard passed its own examples and the lenses asked nothing more, but it missed a multi-line `case`, files with no `.sh` name, `Darwin` and an anchored `=~`.

Enforced by: `tests/unit/lens-check-escapes-test.sh` CE1.

## Amendment 2026-11-26 (#2630) — a suspicion sends the change round once a run

- **A suspicion blocks the first time a lens raises it in a run**, and the stage its `fix:` names is asked to run what would confirm it (ADR-040 §3, amended 2026-11-26). It is the line it is about — its file and quote — and the lens keeps which it sent in its own result (`sent_suspicions`); sent already in the run, it blocks nothing and is listed for a person as before.

Enforced by: `plugins/agent/review-lens/tests/review-lens-asks-test.sh` S4, S11–S15.
