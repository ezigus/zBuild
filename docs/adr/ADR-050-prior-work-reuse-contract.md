# ADR-050 — Prior-Work Reuse Contract (durable artifact store + per-stage self-seeding)

**Status:** Accepted (2026-07-23)
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

A stage does not know or care _which_ source supplied the content; it injects the
result into its prompt as an advisory `## PRIOR <X> (reference — refine, do not
recreate)` section.

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

**One hazard this creates, to be designed for rather than discovered.** *Git wins* plus *persist
failed* loses unpushed work: a run whose push fails, followed by a re-run, has its newer local
artifacts overwritten by the older git copy. The window is small because persist is always-run, but
it is real. Hydrate must detect "local is newer than git" and refuse or warn rather than clobber
silently, and a failed persist must leave a marker hydrate honours.

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

## References

- [ADR-001](ADR-001-plugin-contract.md) — plugin contract (this adds the reuse obligation).
- [ADR-006](ADR-006-resume-contract.md) — resume contract (skip-completed); distinct from this.
- [ADR-013](ADR-013-canonical-stage-list.md) — stage list / primary outputs.
- [ADR-015](ADR-015-stage-io-capture.md) — stage-io; the `## PRIOR X` sections ride the input banner flow.
- [ADR-047](ADR-047-stage-agnostic-mechanics.md) — stage-agnostic mechanics (engine names no stage).
- Issue #1581; PR #1582 (foundation: seam, `core/state/artifact-persist.sh`, intake adoption, PR reuse).
