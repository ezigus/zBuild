# ADR-052 — The per-run worktree is engine-owned run infrastructure

**Status:** Accepted (2026-07-28)
**Issue:** #1640 (Bugs-found EPIC #1600) — supersedes the ownership model introduced by #888
**Related:** [ADR-023](ADR-023-install-isolation.md) (engine isolation — "which zBuild code runs"),
[ADR-051](ADR-051-engine-owned-stage-keyed-data-provision.md) (engine-owned, stage-keyed data
provision), [ADR-047](ADR-047-stage-agnostic-mechanics.md) (stage-agnostic mechanics),
[ADR-001](ADR-001-plugin-contract.md) (plugin contract),
[ADR-006](ADR-006-resume-contract.md) (resume contract), [ADR-024](ADR-024-subprocess-env-isolation.md)
(subprocess env isolation).

## Context

#888 gave each run its own `git worktree` so concurrent runs stop racing one working tree's
`.git/index` and refs. The worktree was acquired by the **intake plugin**: intake picked the work
branch, called `zbuild_worktree_prepare`, `cd`'d into the returned path, and exported
`ZBUILD_REPO_ROOT`.

That ownership does not survive the dispatch model. Each stage runs in its own subshell, so
intake's `cd` and `export` die with it. Every later stage fell through to

```bash
local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
```

resolved from the **runner's** untouched CWD — the main checkout, on whatever branch it held.
The runner did re-root, but only on resume (`if $resume_mode`), so the common path was unprotected.

The consequences were not hypothetical (#1640):

- **CI run for #1318:** the build stage committed to `main` inside an ephemeral runner. The work
  branch never moved. 3h49m of model work was discarded at teardown.
- **Local run for #1611:** commit `cdf1b21` landed on `main` in the operator's own checkout, with
  no warning, and had to be recovered by hand.
- **Diff contamination:** because the run worked in the shared checkout, a concurrent human merge
  to `main` was absorbed into the run's own diff and attributed to the pipeline.

Three properties of the failure drive this decision:

1. **The damaging step was silent.** The commit was not refused and nothing warned. `pr_open` was
   the only thing that ever caught it, at the very end of the run — so any run that died earlier
   reported nothing at all.
2. **Noticing after the fact does not fix the class.** Having the engine read intake's
   `intake-worktree.txt` between stages couples `core/pipeline` to one plugin's private artifact
   (against [ADR-047](ADR-047-stage-agnostic-mechanics.md)), depends on dispatch ordering, breaks
   for any template whose first stage is not intake, and still leaves intake itself running in
   the caller's tree.
3. **The tree is a property of the run, not of a stage.** `run_id` and `state_dir` are already
   engine-owned; `scripts/lib/worktree.sh` already places the worktree *under the run root*
   (`zbuild_run_root`). Ownership was the only part that sat in the wrong layer.

The enabling fact: acquiring a worktree **needs no branch**. `zbuild_worktree_prepare` already
created it `--detach` precisely so intake's four branch paths stayed the single source of truth.
Creation therefore needs only `run_id` — which the engine has, and intake does not own.

## Decision

**The engine acquires the run's worktree before the first stage dispatches. No plugin knows
worktrees exist.**

1. `zbuild_worktree_acquire <run_id> [main_repo_root]` (`scripts/lib/worktree.sh`) creates-or-reuses
   the per-run detached worktree. It takes **no branch**. Reuse is keyed on `run_id`, which is what
   makes resume land in the tree the earlier stages worked in.
2. `_runner_enter_worktree <state_dir> <run_id>` (`core/pipeline/runner.sh`) runs as the **last**
   step before any stage dispatch. It records the path in `run-worktree.txt`, exports
   `ZBUILD_REPO_ROOT`, and **`cd`s** there.
3. The runner both exports *and* enters. Exporting alone would leave every `$(git rev-parse
   --show-toplevel)` / `$(pwd)` fallback resolving to the main checkout — which is the bug.
4. `ZBUILD_MAIN_REPO_ROOT` preserves the operator's checkout across the re-root, for the checks
   that must target it.
5. **Ordering.** Everything before the re-root is engine bookkeeping that belongs in the main
   checkout (state dir, events, per-repo template overlay, prior-artifact restore, the
   `--self-host` snapshot of the operator's working tree). Everything after is stage work.
6. **Fail-closed** ([ADR-001](ADR-001-plugin-contract.md)). A recorded worktree that has vanished,
   or a failed acquire, aborts the run. Continuing in the main checkout is precisely the silent
   damage this exists to prevent.
7. `ZBUILD_NO_WORKTREE=1` remains the opt-out and is byte-identical to in-place behaviour.

### Consequences for intake

Intake loses its worktree block, its `zbuild_worktree_prepare` call, its `ZBUILD_RUN_ID`-unset
fallback, and its `worktree.sh` import. It runs its existing four branch paths in whatever tree it
is standing in — which the engine has already made the right one.

One check had to move rather than disappear. `_intake_check_preflight` refuses a dirty working
tree, and its #888 comment deliberately ran it against the main tree "so worktree-mode is not
quietly more permissive than in-place mode." Since the engine now re-roots *before* intake, `$PWD`
is a tree the engine just created — always clean, never mid-rebase — so preflighting it would be
vacuous. The preflight therefore targets `ZBUILD_MAIN_REPO_ROOT`, falling back to `$PWD` for
in-place runs and direct callers.

`zbuild_worktree_prepare` is deleted: it existed only for intake's call site, and its documented
contract ("the caller cd's into the returned path") is no longer true of anyone.

## Amendment (#1869) — releasing a finished run's tree

**Status:** Accepted (2026-08-13)

The decision above leaves one gap it did not anticipate. Nothing releases a run's worktree when the
run ends, so an aborted run keeps its branch checked out indefinitely. Since every `pipeline start`
mints a new run and a new tree, the *next* run of the same issue found its branch held and died at
intake — a bare re-run collided with its own predecessor, permanently.

Only intake can detect this: the collision surfaces when it checks the branch out, and which branch
that is remains intake's decision (§Decision 1). But whether a worktree may be released is a
question about run infrastructure, which is the engine's.

**Amended rule.** When its checkout is refused because another worktree holds the branch, intake may
ask the engine to release **that specific holder**, by path, and retry once —
`zbuild_worktree_reclaim_dead <holder>` in `scripts/lib/worktree.sh`. It never creates, enters,
chooses, or locates a worktree, and the path it passes is one git handed it in the refusal. The
engine decides alone, and refuses unless it can prove the holding run has finished.

This narrows "no plugin knows worktrees exist" (§Consequences for intake, which removed intake's
`worktree.sh` import) to: **no plugin decides which tree it works in.** That was always the property
under threat — #888's defect was intake choosing and entering a tree, not intake naming one.

**Safety.** Reclaiming is not destructive: a branch ref lives in the repository, not in the worktree
holding it, so removing a clean tree leaves the branch and its commits intact and the next run
continues from where the dead one stopped. The refusals carry the weight — a run that is
`in_progress` with a fresh `updated_at` ([ADR-006](ADR-006-resume-contract.md)'s staleness gate,
named once as `zbuild_run_is_live`); a run whose liveness cannot be established at all; and a tree
holding uncommitted work, which `git worktree remove` refuses on its own because this deliberately
never passes `--force`.

**Events.** `intake.branch.reclaimed` / `intake.branch.reclaim_refused`. These *do* keep the
`intake.` prefix — unlike the acquisition events above — because they record what intake did about
its own branch, not how the engine manages trees.

## Alternatives considered

**Drop the `if $resume_mode` guard and re-root at the top of each dispatch loop.** This is the fix
#1640 proposes literally, and it is the smallest diff. Rejected: it keeps `core/pipeline` reading a
plugin's artifact, keeps the ordering hazard (the file must exist before the *next* dispatch), keeps
intake itself in the caller's tree, and would need the hook installed in both dispatch loops — two
places for a future change to miss, which is how #888's own mechanism went inert.

**Add a generic stage→engine "I moved the repo root" channel.** More general, but it legitimises a
stage mutating run-wide infrastructure mid-run. The tree a run works in should not be negotiable
after the run starts.

**Leave it to `pr_open` to refuse a wrong-branch push.** Status quo. It is a terminal check on a
loss that has already happened, and it never fires on runs that die earlier — the quieter and more
dangerous case (#1611).

## Verification

- `tests/integration/worktree-run-isolation-test.sh` — drives the **real runner** across **two
  dispatched stages**. An assertion inside intake's own shell cannot observe this defect, which is
  why #888's coverage was green while the live path was broken. Asserts the main checkout's HEAD
  *and* branch are byte-identical across a run, that stage 2 resolves its repo root to the run's
  worktree, and — separately — that a run **failing before any `pr` stage** still leaves the main
  checkout intact. Verified red at the merge-base and under mutation of the re-root call.
- `tests/integration/worktree-ownership-test.sh` — the seams: intake's tree-agnosticism, the
  preflight targeting the main checkout, fail-closed on a vanished worktree, legacy
  `intake-worktree.txt` back-compat, and acquire reuse.

## Compatibility

`run-worktree.txt` replaces `intake-worktree.txt`. The legacy name is still read back, so a run
started by the previous engine and resumed by this one lands in its existing tree instead of being
stranded in the main checkout.

## Implementation Notes (#1640)

**Seams.**

- `scripts/lib/worktree.sh` — `zbuild_worktree_acquire`. Reuse requires the path to be a real work
  tree (`git -C "$wt" rev-parse --show-toplevel` must resolve to `$wt`), so a plain directory
  squatting on the path is rc=4 rather than a silent wrong-tree run. Creation carries a
  post-condition: a `git` that exits 0 without creating the tree (a PATH shim) is rc=5 with a
  message naming the cause, instead of a confusing `cannot cd` from the caller.
- `core/pipeline/runner.sh` — `_runner_enter_worktree`, plus `_runner_worktree_record` for the
  new/legacy record-name fallback. Replaces `_runner_restore_worktree` and its `if $resume_mode`
  call site; one function now serves fresh and resume alike.
- `state_dir` is absolutized immediately before the exports that derive from it. The runner `cd`s
  later, and a relative `ZBUILD_STATE_DIR` would otherwise resolve against the new CWD from that
  point on — half a run's artifacts in one place, half in another.

**Events.** `pipeline.worktree.entered` / `.missing` / `.acquire_failed` replace
`pipeline.resume.worktree_restored` / `.worktree_missing` and `intake.worktree.entered` /
`intake.refused.worktree_prepare_failed` in `config/event-schema.json`. The names lose their
`resume.` and `intake.` prefixes because the mechanism belongs to neither.

**Environments where worktrees cannot work.** `tests/golden/parity/run-fixture.sh` shims `git` on
PATH, so `git worktree add` exits 0 without creating anything. It opts out with
`ZBUILD_NO_WORKTREE=1`, the same way it already opts out of intake's branch path with
`ZBUILD_INTAKE_SKIP_BRANCH=1`. The engine deliberately does **not** infer a silent in-place
fallback from a failed acquire: falling back quietly to the main checkout is the exact behaviour
this ADR exists to remove.
