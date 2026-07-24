# ADR-050 — Prior-Work Reuse Contract (durable artifact store + per-stage self-seeding)

**Status:** Accepted (2026-07-23)

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
