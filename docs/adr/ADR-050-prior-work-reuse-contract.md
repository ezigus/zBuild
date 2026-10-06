# ADR-050 — Prior-Work Reuse Contract (durable artifact store + per-stage self-seeding)

**Status:** Accepted (2026-07-23)
**Amended:** 2026-10-06 (#2326) — §8: anything a stage reads from an earlier run's saved work is labelled as that run's, for reference only, wherever it shows (input index, prompts, input events), and a stage that judges results never counts it as this run's result.
**Amended:** 2026-10-06 (#2324) — design-gate no longer writes `data.design_sha`; its only reader was the reuse rule #2299 withdrew. Every statement below now names its test.
**Amended:** 2026-10-05 (#2299) — design always runs. The #2225 rule that kept a prior run's design without a model call is withdrawn; a restored design reaches the prompt as a reference to check (§6: never skip the stage on the basis of prior output).
**Amended:** 2026-09-16 (#2111) — a run that ends `aborted` with `reason=llm_rate_limited` (ADR-054 §6) persists like any other outcome; re-adding the trigger label after the reset resumes from the state branch. The daemon's completion comment names the reset text so the operator knows when.
**Amended:** 2026-08-23 (#141) — §7: git is the store, the folder is the working copy, and the push moves from CI into an always-run `persist` stage (ADR-059)

**Confirmed unchanged:** 2026-08-12 (#1768, ADR-055 §1.2) — ADR-055's data contract was reviewed against this one and prior-work reuse is deliberately **outside the input model**. It is not a declared input, not a third source kind, and not `external`. §1 below is the reason: a stage detects *its own* prior artifact in its own working area, so there is no producer to resolve and no wire to declare. Modelling it as an input would require the engine to know that `build`'s prior `build_summary` belongs to `build` — exactly what §1 forbids. No change to this ADR.

> **Memory type.** This ADR governs **prior-work memory** — the durable output of a
> prior run of the _same issue_ (a design.md, a work branch, an open PR) that a
> later run reuses as advisory seed. It is distinct from the **pipeline-resume
> memory** of [ADR-006](ADR-006-resume-contract.md): resume _skips_ completed
> stages to continue an interrupted run; this contract makes every stage _re-run_,
> seeded from prior work. The two are orthogonal and may coexist.

## Context

Re-triggering a dogfood for an issue that already had a run threw the prior work
away or aborted: CI `state/` is ephemeral (gitignored), so plan/design/impact/etc.
were regenerated from scratch; intake refused an existing remote branch; and the
PR stage aborted when a PR already existed. The observed cost was real — a correct
~2-hour run (issue #1569) was discarded and re-done, then aborted on a stale PR.

We want the opposite: **every stage runs, and each stage picks up its own prior
work as advisory input** ("reference it, don't blindly trust it, improve from
there"), identically locally and in GitHub CI, and for BOTH intra-cycle iterations
and cross-run restarts — through one mechanism, not two code paths.

This must hold without violating the plugin contract ([ADR-001](ADR-001-plugin-contract.md))
or the stage-agnostic mechanics rule ([ADR-047](ADR-047-stage-agnostic-mechanics.md)):
the engine must not learn stage names or artifact meanings.

## Decision

### 1. Two layers, strict separation

- **Engine / orchestrator = generic, stage-agnostic persistence.** It never knows
  which stages exist or what any artifact means. Its sole job: whatever a stage
  saved to the run's artifact area is preserved and restored into a consistent
  location so it is available to a later run. It snapshots a _directory_; it never
  branches on stage identity.
- **Stage plugin = self-detection + consumption.** A stage knows only ITS OWN
  artifact. It asks "is my prior output present in my working area?" and, if coded
  to, reuses it as advisory seed. A stage NEVER reaches into pipeline state, run
  history, or resume logic — detection is just "does my file exist here?", which
  the engine's generic restore guarantees.

### 2. Durable store = a separate state branch (never merged to main)

The engine persists the artifact area to a sibling branch **`zbuild/state/issue-<N>`**,
distinct from the work branch `zbuild/issue-<N>-ci`.

- It is **never part of the work branch's history**, so it cannot merge to main and
  never pollutes the PR diff. (Legacy shipwright committed state into the _work_
  branch with no strip-before-merge, so its snapshots would reach main; the separate
  branch fixes that while keeping the "durable on a branch, restored by fetch" shape.)
- It is a real branch (not a hidden `refs/…` ref) so a stored document has a
  browsable GitHub blob URL — e.g. design.md is linkable.
- Snapshots use git plumbing (`hash-object` → `commit-tree` → `update-ref`) so they
  **never touch the working tree or the real index**. Restore uses `git archive`.

### 3. What is stored, and what is NOT

- **Stored (durable):** the work branch (code commits), the GitHub PR, and the
  snapshotted artifact area (each stage's primary artifact — plan.json, design.md,
  impact.json, build-summary.json, lens-*.json, scope-manifest.md, …).
- **Not reused (always re-evaluated fresh):** the verdicts of **deterministic
  gates** — test, shape-floor, acceptance-gate, secret-scan, gate-aggregator,
  design-gate, review-aggregator. They are cheap and deterministic, and reusing a
  stale "pass" against changed code is a correctness hazard (it produced observed
  false-greens). Gates re-run against current git state every time.

### 4. Persist timing

Commit a snapshot at **each stage boundary** (so a mid-run crash/rate-limit still
leaves every completed stage recoverable); **push the state branch once at the end**,
pass or fail (reusing the existing `if: always()` push step). Identical snapshots
are no-ops (no empty commits).

**Amendment (#1878) — the snapshot was never invoked at all.** As shipped in #1581
its only call site sat inside the runner's **legacy linear stage loop**
(`runner.sh`, the `for stage in "${active_stages[@]}"` loop). That loop is
unreachable for every shipped template: a template containing a `cycle:`, `map:` or
`parallel:` unit sets `_run_dispatch_units=1`, and every terminal branch of the
dispatch-unit block above it returns. Both `simple.yaml` and `deployed.yaml` yield
cycle units, so the linear loop never executes — and the store was therefore always
empty, which is why the restore on the live path always found nothing. This is item
1 of #1807.

The snapshot is now one helper (`_runner_snapshot_artifacts`) invoked from the
**live** dispatch-unit completion sites — the `stage:` arm (leaf stages: intake,
plan, impact, pr), the parallel-group arm, the map-group arm — and from the cycle
orchestrator's single member-completion funnel
(`_cycle_emit_member_dispatch_complete`, rc=0 only, matching the leaf contract) so
that `design`, `design-gate` and the whole of `build_test_cycle` are covered.

The call in the legacy loop is left in place and now routes through the same helper:
it is unreachable today, but leaving a *divergent* copy behind is how this class of
defect is manufactured. #1807 owns removing the loop; until then the two paths agree.

**Amendment (#1878) — persistence is advisory but never silent.** A snapshot
reports one of `saved | empty | unchanged | failed` on
`_ARTIFACT_PERSIST_LAST_STATUS`, and a failure carries the failing git operation
and its stderr on `_ARTIFACT_PERSIST_LAST_REASON`. The engine emits
`artifact.snapshot.failed` / `artifact.restore.failed` accordingly. Previously the
call site swallowed stderr and the library returned `0` for genuine no-ops, so the
engine reported `artifact.snapshot.saved` for a snapshot that had saved nothing —
and a real failure produced no signal anywhere. A single unstageable file now
skips-and-counts rather than discarding the whole snapshot.

**Amendment (#1921) — persist's own result joins the store, and what `pushed: null` means.**
Every stage's result file reaches the state branch except the one whose job is
durability. `persist_run` wrote `persist-result.json` *after* its only snapshot, so
the snapshot could never contain it, and the work branch carries code only —
measured on `zbuild/state/issue-1836`: 90 commits, eight `*-result.json` files, no
`persist-result.json` in any of them. The stage with no durable record of itself is
the one an operator most needs a record of, because its failure mode is silence.

The order is now: snapshot → **write the result** → snapshot again → secret gate →
push **once** (§4 unchanged) → rewrite the local copy with the push outcome. The
second snapshot exists because the first cannot contain the file that describes it.
The gate moved *after* the write so it scans `persist-result.json` too — nothing
reaches origin unscanned.

**The second snapshot AMENDS the first rather than stacking on it**, so the branch
gains exactly **one** commit per persist run. A second commit whose only delta is a
status file is precisely the empty-commit spam this section already rules out.
Amend is opt-in per call and used *only* when the caller created the current tip in
that same invocation: when persist's own snapshot reports `unchanged` or `empty` it
created nothing, the tip belongs to an earlier stage boundary, and amending there
would silently delete a legitimate commit. In that case the second snapshot extends
normally — still one commit.

**The branch copy carries `data.pushed: null`, and that does not mean the push
failed.** A push cannot record its own outcome; recording `false` would be a lie
whenever the push then succeeded, which is the common case. The authoritative value
is in the **local** `persist-result.json` and in the CI job log. `null` reads as
"not attempted at the time this was written". Anything reading the branch copy and
treating `null` as failure is reading it wrong — this paragraph exists because that
misreading is the same class of defect #1921 was filed to eliminate.

Note this is *stored, not reused* — the same category §3 already puts deterministic
gate verdicts in. Nothing seeds from it; it is a record.

**Amendment (#1878) — push order.** The state-branch push runs **before** the
work-branch push in `zbuild-pipeline.yml`. Both live in one `run:` block and the
work push legitimately `exit 1`s on failure, which previously skipped the state
push entirely — the durable store was sacrificed to a work-branch failure, which is
precisely the case it exists to survive (observed on run 31798796692, where the work
push was rejected under #1780).

### 5. The unified prior-output seam (one path for cycle AND restart)

Consuming stages read prior work through a single helper
`scripts/lib/prior-output-reader.sh` → `_read_prior_output <artifact>`, with one
resolution order (first hit wins):

1. **Intra-cycle** feedback (`ZBUILD_CYCLE_FEEDBACK_DIR/prior_<field>.txt`, iter ≥ 2)
   — a later cycle iteration refining an earlier one within the same run.
2. **Cross-run restored** (`ZBUILD_RESTORED_ARTIFACTS_DIR/<artifact>`) — the prior
   run's artifact, placed there by the engine's restore.
3. **Local state fallback** (`${ZBUILD_STATE_DIR}/artifacts/<artifact>`).
4. Not found → empty, `return 0` (silent-fail).

A stage does not choose _which_ source supplied the content; it injects the
result into its prompt as an advisory `## PRIOR <X>` section. Amended by §8
(#2326): when the source is the earlier run's copy, the section says so —
`_prior_output_path` returns the path, and `prior_output_is_earlier_run` tells
the stage which kind it got.

### 6. Stage-authoring contract (what a new stage MUST do)

A plugin author, when creating or changing a stage, MUST observe:

- **Declare a primary artifact** (manifest `outputs:` with `primary: true`). That
  file — and only what the stage writes to the artifact area — is what gets
  snapshotted. The engine needs no per-stage code.
- **To reuse prior work**, read via `_read_prior_output` and treat the result as
  **advisory** ("reference, don't fully trust; verify against current inputs").
  Never skip the stage on the basis of prior output; never read pipeline/run state.
- **If the stage is a deterministic gate**, it MUST re-evaluate current state and
  MUST NOT reuse a prior verdict.
- **Never write anything that must not reach main into the work branch** — durable
  cross-run state belongs on the state branch (engine-managed), not in the code diff.

### 7. Amendment (#141) — git is the store, the folder is the working copy, and every run pushes

**Status:** Accepted (2026-08-23). See [ADR-059](ADR-059-issue-vs-run-keying.md) §3.

This ADR is already keyed by the issue, so ADR-059's layout does not compete with it. What ADR-059
settles is **which of the two is authoritative**, because there are now two places an issue's prior
work can live: the state branch above, and the on-disk `issues/<N>/artifacts/` directory.

**Git is the store. The folder is the working copy. On a disagreement, git wins.**

The disk is not a second store and does not gain independent authority by being closer to hand. It
is what a run reads and writes during its life; §2's branch is what survives it.

**The push moves out of CI and into the pipeline.** §4 says *"push the state branch once at the end,
pass or fail"*, and the #1878 amendments below add ordering and advisory-failure rules on top of it —
all of which read as engine behaviour. They are not. `core/state/artifact-persist.sh` has **no `git
push`**; it writes a local ref. The only state-branch push in the repository is a shell block in
`.github/workflows/zbuild-pipeline.yml`. A local run therefore snapshots to a branch nobody ever
sends anywhere, which is why #1921 measured hundreds of local commits and zero on origin.

ADR-059 §3 fixes this by making persistence a **stage** rather than engine code:

- **hydrate**, before intake — pulls the state branch into the folder. Git wins; it overwrites.
- **release**, at the end, **always-run**, short timeout — frees live resources, deletes nothing.
- **persist**, at the end after release, **always-run**, longer timeout — snapshots **and pushes**.

`_artifact_persist_restore` (`core/pipeline/runner.sh:1813`) becomes hydrate; the RUN-END snapshot
and the push become persist. This file stays as the shared library both stages source.

**Corrected 2026-08-23 (#1071).** An earlier draft said `_runner_snapshot_artifacts` "becomes
persist", which reads as moving it wholesale. §4's per-stage-boundary snapshots — six call sites —
are that section's own design and **stay engine-side**. The persist stage owns what never existed:
a final snapshot at run end, and the push. `_artifact_persist_push` is new in this file; nothing
in it has ever pushed before. The #1878 amendments survive intact and finally have somewhere to be enforced: the
push-order rule becomes stage order in the template, and the "advisory but never silent" rule
becomes the persist stage's own disposition.

**§3's exclusion is unchanged and gets no relaxation here.** Deterministic gate verdicts are still
*"always re-evaluated fresh"*. That rule exists because reuse produced **observed** false greens, and
a durable, pushed, cross-machine store makes stale-verdict leakage easier rather than harder.
Widening what may be reused is a separate decision from moving where work lives, and must not ride
along with it.

**A hazard was flagged here and is now DISPROVEN — recorded rather than deleted, because the
reasoning is what stops it being re-invented.** The claim was: *git wins* plus *persist failed*
loses unpushed work, because a re-run would overwrite newer local artifacts with an older git copy.
Building #1074 showed the sequence cannot happen:

- **Restore never writes over live artifacts.** It extracts into a separate `restored-artifacts/`
  area, and `input-resolve.sh` reads the live path first — a stage's own output is never replaced
  by an older copy of itself.
- **Fetch cannot move a local snapshot.** `git fetch` updates only the remote-tracking ref;
  `refs/heads/<branch>` is untouched, so unpushed work survives.
- **The local ref wins on read, deliberately.** `_artifact_persist_restore` prefers
  `refs/heads/<branch>` over `refs/remotes/origin/<branch>` precisely because the local one may hold
  more. "Git wins" is about **durability** — where work survives a dead laptop — not about read
  precedence.

So hydrate needs no "local is newer" detector and persist needs no failure marker. What hydrate
does need, and what was actually missing, is the **fetch**: on a fresh clone neither ref exists, so
restore reported "first run" for an issue with plenty of prior work.

### 8. Amendment (#2326) — an earlier run's work is labelled, and never counted as this run's result

**Status:** Accepted (2026-10-06). The same rule ADR-063 §5 (#2325) applies across the rounds of one run,
applied across runs.

A stage may read what an earlier run saved (restored into `$ZBUILD_RESTORED_ARTIFACTS_DIR`). That work
was not produced by this run, and the earlier run's result may not have been accepted. Until #2326
nothing said so: a declared input with no copy from this run fell back to the earlier run's copy
silently (#2095 keeps that fallback), the index and the prompt listed it like any other input, and
review-aggregator would have counted a lens's verdict from last run for a lens that wrote nothing this
run.

- **Labelled everywhere it shows.** One wording, defined once (`ZB_EARLIER_RUN_LABEL` in
  `scripts/lib/prior-output-reader.sh`): *"from an earlier run — reference only, not this run's
  result"*.
  - The input index (`stage-inputs/<stage>.json`) lists every path served from an earlier run's copy
    under `earlier_run`. A path from this run is not listed; with none, the key is absent.
  - The prompt's input block puts the label next to each such path and says what it means.
  - The engine records each one as a `stage.input.earlier_run` event (`stage`, `input`, `path`).
  - A stage that seeds itself from its own earlier work — design, plan, impact, build's prior summary —
    labels it when it came from an earlier run, and only then.
  - Notes an earlier run saved as it went (the checkpoint, ADR-063 §5) appear under
    `### NOTES FROM AN EARLIER RUN (reference only)`, not as this stage's own exploration to build on.
- **Never counted as this run's result.** A stage that judges results — a gate (`convergence: gate`) or
  a stage that aggregates others' results (`aggregates:`, e.g. review-aggregator) — is never handed an
  earlier run's copy. For it, a result this run did not produce is missing: an optional input is
  handed over as this run's (absent) path, and a required one refuses the dispatch (`INPUT_MISSING`).
  This extends §3 from the gate's own verdict to every result a gate reads.
- **Hand-overs keep working.** A stage that does not judge still reads the earlier copy when this run
  has none (#2095); it is labelled, not withheld.

## Consequences

- Re-triggering an issue continues the prior attempt instead of restarting it:
  intake adopts the existing branch, stages seed from prior artifacts, the PR is
  updated rather than duplicated.
- The engine stays stage-agnostic (upholds ADR-047); the plugin contract (ADR-001)
  gains an artifact/reuse obligation but no new engine coupling.
- The state branch accrues history per issue; it is disposable and never merged.
- Deterministic-gate freshness is guaranteed, avoiding stale-pass false-greens.
- A new operational branch namespace (`zbuild/state/*`) must be excluded from any
  label/PR automation and from branch-cleanup that assumes work branches.

## Implementation Notes (#1581 / PR #1582)

Foundation landed in PR #1582:

- `scripts/lib/prior-output-reader.sh` — `_read_prior_output` (the unified seam, §5).
- `core/state/artifact-persist.sh` — `_artifact_persist_snapshot` / `_artifact_persist_restore`
  (git-plumbing snapshot to `zbuild/state/issue-<N>`, working-tree-safe; §2, §4).
- `plugins/agent/intake/plugin.sh` — adopts an existing remote work branch
  (`intake.branch.adopted`) instead of refusing.
- `plugins/tool/pr-open/plugin.sh` — reuses an existing open PR (`status=updated`)
  instead of aborting.

Follow-up — LANDED (makes the foundation live):

- Runner integration (`core/pipeline/runner.sh`): restore prior artifacts once at
  startup, exporting `ZBUILD_RESTORED_ARTIFACTS_DIR` at the restored `artifacts/`
  subdir; snapshot the artifact area to the state branch at each completed stage
  boundary. Both best-effort and stage-agnostic (the engine names no stage).
- Consumer wiring: design & build route their existing prior-work readers through
  `_read_prior_output` (design also emits a state-branch blob link); plan, impact,
  and review-lens read their own prior artifact and inject a `## PRIOR X` section —
  gated on `ZBUILD_RESTORED_ARTIFACTS_DIR` (cross-run restore only) so a leaf stage
  never picks up stale cycle env or its own same-run output.
- CI workflow (`.github/workflows/zbuild-pipeline.yml`): fetch the work + state
  branches into remote-tracking refs before the run (so intake can ADOPT the work
  branch and the runner can RESTORE the state branch); push the state branch pass
  OR fail.
- pr-open: the 0-commit preflight is remote-aware — if `origin/<work-branch>` has
  commits it proceeds to reuse/open the PR instead of aborting (fixes the #1570
  cold-start "nothing to ship").

Deterministic gates are intentionally left to re-evaluate fresh (§3).

## Amendment (2026-09-29, #2225): the run's resume intent reaches every stage

Prior-work reuse had no switch a stage could see. After a usage-limit abort,
re-adding `zbuild-run` starts a new run that `hydrate` seeds with the old
artifacts — but nothing told a stage it was a resume, so design ran again every
time (~20 min on #1835 and #1837) and the loop's rounds reset.

- **One variable, `ZBUILD_RESUME`**, exported by the runner before any stage
  runs: `1` by default (reuse prior work), `0` with `--no-resume` — and
  `ZBUILD_RESUME=0` in the environment is the same as the flag, as
  `ZBUILD_SELF_HOST=1` is for `--self-host`. The pipeline workflow has a
  `no_resume` input (like `dry_run`); the daemon leaves the default.
- **`0` recreates.** `hydrate` restores nothing. It still fetches and adopts the
  saved-work history, so the next snapshot extends it instead of force-pushing a
  new one over it (review #2229).
- **Each stage decides what `1` means for it.** Plan continues from its
  checkpoint; test-author and build from their committed files. design
  always runs (amended by #2299, below): the restored design is in its prompt
  as a reference, never kept as this run's design.

Verification: `tests/unit/resume-default-test.sh` (R1–R4).

## Amendment (2026-10-05, #2299): design always runs

The #2225 bullet above first let design keep the prior run's design without a
model call when design-gate had passed that exact `design.md`, spec-coverage had
found it covered, this run had no design yet, and `intake.md` was unchanged.
That rule never asked whether the run that wrote the design succeeded, or
whether the design was ever built and tested. #2035 run 37289704344 kept run
37262225813's design in 1 second; that design had been rewritten in the failed
run's last round (SPEC-2/3 relabelled `[guard]`), never tested, and the relabel
went straight into PR #2298. The prompt already tells the model to treat a
prior design as a reference to verify against the current inputs; a skip means
no model ever reads that line.

- **design makes its model call on every run**, resumed or not. It emits no
  `design.reused` (the event is gone).
- **A restored prior design is a reference.** It reaches the prompt under
  `## PRIOR DESIGN (a previous attempt on this issue — a hypothesis, not a
  fact)`, with what has moved since, as §6 and #2172 require.
- design-gate no longer records the hash of the `design.md` it judged
  (`data.design_sha`, removed by #2324): nothing read it once the reuse rule
  was gone.

## Enforced by

- §1 (the engine snapshots a directory, never a stage: files with names no stage has round-trip; the persistence code names no plugin) → `tests/unit/prior-work-reuse-contract-test.sh` C1
- §2 (state branch, never in work-branch history; snapshots never touch the working tree) → `tests/unit/artifact-persist-test.sh`
- §3 (a deterministic gate never reuses a prior verdict: no gate plugin reads prior work; design-gate and gate-aggregator judge the current state despite a restored pass) → `tests/unit/prior-work-reuse-contract-test.sh` C3
- §4 (a snapshot at each stage boundary; a failed snapshot never aborts the run) → `tests/integration/artifact-snapshot-runner-test.sh`
- §4 (#1921: persist's own result joins the store; the secret gate runs before the push) → `tests/unit/persist-stage-test.sh`
- §5 (`_read_prior_output` order) → `tests/unit/prior-output-reader-test.sh`
- §6 (never skip a stage on the basis of prior output — design always runs, the prior design is a reference in its prompt) → `tests/unit/resume-default-test.sh` R5–R11 (#2299)
- §7 (persist is an always-run stage; restore never writes over live artifacts) → `tests/unit/template-always-run-test.sh`, `tests/unit/stage-input-resolve-precedence-test.sh`
- §7 (the local ref wins on read: unpushed local work is what restore returns) → `tests/unit/hydrate-stage-test.sh` SPEC-2
- Implementation notes (intake adopts an existing remote work branch) → `tests/integration/intake-branch-ahead-count-test.sh`
- Implementation notes (pr-open edits the existing open PR, never opens a second, and reports `status=updated`) → `tests/unit/prior-work-reuse-contract-test.sh` C5
- #2225 (`ZBUILD_RESUME` defaults to 1; `--no-resume` restores nothing yet still fetches and adopts) → `tests/unit/resume-default-test.sh` R1–R4
- #2324 (design-gate's result has no `design_sha`) → `tests/unit/resume-default-test.sh` R12
- §8 (#2326: the input index marks an input served from an earlier run's copy, and not this run's; the prompt's input block labels it; the `stage.input.earlier_run` event records it; a gate and review-aggregator treat a result that exists only as an earlier run's copy as missing; a stage that does not judge still reads it) → `tests/unit/earlier-run-reference-test.sh` E1–E5
- §8 (#2326: design, plan, impact, build's prior summary and an earlier run's saved notes are labelled in the prompt when they came from an earlier run, and not when they came from this run) → `tests/unit/earlier-run-prompt-label-test.sh` L1–L5
- #2111 (a run aborted with `llm_rate_limited` persists — persist pushes the state branch; the daemon's completion comment names the reset time and says to re-add the label) → `tests/unit/prior-work-reuse-contract-test.sh` C6

## References

- [ADR-001](ADR-001-plugin-contract.md) — plugin contract (this adds the reuse obligation).
- [ADR-006](ADR-006-resume-contract.md) — resume contract (skip-completed); distinct from this.
- [ADR-013](ADR-013-canonical-stage-list.md) — stage list / primary outputs.
- [ADR-015](ADR-015-stage-io-capture.md) — stage-io; the `## PRIOR X` sections ride the input banner flow.
- [ADR-047](ADR-047-stage-agnostic-mechanics.md) — stage-agnostic mechanics (engine names no stage).
- Issue #1581; PR #1582 (foundation: seam, `core/state/artifact-persist.sh`, intake adoption, PR reuse).
