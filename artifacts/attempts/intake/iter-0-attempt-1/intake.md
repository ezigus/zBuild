[bug] the frozen legacy/ import is materialised into every issue worktree — ~50% of the tree, swept by every repo-wide search

> **Updated 2026-10-08** (Phase 2 re-verification against main 2ae004fa): defect re-confirmed in code; three constraints found that the fix must respect are added under **Constraints** below, and the first acceptance item now keeps `legacy/migrated/`. Build Mode re-derived under ADR-057: gate 4 (Dogfood) — worktree setup runs before intake, but a broken setup fails loudly and CI exercises it, so gate 3 does not fire.

> **Updated 2026-09-29** (Initiative 1.3 alignment audit, main 900db6b0): figures re-measured, the ADR-059 per-issue re-keying (now landed) folded into the body, and the title corrected from "every run worktree" to "every issue worktree".

Part of #1795 (Phase 2).

**Classification: ENGINE — worktree materialisation (`scripts/lib/worktree.sh`).**

`legacy/` is a frozen upstream import that is contractually forbidden to execute. On main 900db6b0 it is **725 tracked files, 12.1 MB of the 24.4 MB tracked tree (~50%), ~296k lines** — and it is materialised into every issue worktree. `scripts/lib/worktree.sh:190` does a plain `git worktree add --detach`; there is no sparse-checkout anywhere in `core/`, `scripts/` or `plugins/`.

[ADR-059](../blob/main/docs/adr/ADR-059-issue-vs-run-keying.md) keys the worktree by **issue**, not run, so `legacy/` is materialised once per issue rather than once per run. That reduces the first cost; it does not remove either one:

1. **Materialisation** — once per issue.
2. **Every repository-wide search the plan and build agents perform sweeps it.** That cost is per *agent turn*, not per worktree creation, and it is the half that burns model context. It is unchanged by the re-keying.

The repo already excludes `legacy/` from call-graph analysis (`scripts/lib/call-graph.sh:55-60`) and linting (`scripts/lib/lint-grep-c.sh`), so the exclusion is an established convention — it was never applied to the worktree.

*(History: filed 2026-08-08 against per-run worktrees, measured at 13 MB / 57% of the tree; the 2026-08-23 ADR-059 update is folded in above.)*

## Fix
Exclude `legacy/` as a property of how the tree is materialised (e.g. sparse-checkout). A per-issue tree is long-lived, so "delete `legacy/` after checkout" would silently reintroduce it on every `git checkout` inside that tree over the issue's life.

## Constraints (verified 2026-10-08)
- **`legacy/migrated/` must stay materialised.** `tests/unit/legacy-e1-tombstone-test.sh:13-14` asserts `$REPO_ROOT/legacy/migrated/e-1.md` exists, and the suite runs inside the worktree. Every other test that names a `legacy/` path asserts its *absence* or builds its own fixture tree, so it is unaffected.
- **A reused worktree must get the exclusion too.** `zbuild_worktree_acquire` returns early for an existing registered worktree (`scripts/lib/worktree.sh:163-182`); a fix applied only after `git worktree add` (`:190`) leaves every resumed run with the full tree.
- **The sparse setting must be per-worktree.** Plain `git sparse-checkout set` in a linked worktree can write repository-wide config and make the operator's main checkout sparse. Use per-worktree config (`extensions.worktreeConfig` / `git sparse-checkout` run inside the worktree) and assert the main checkout is unchanged.
- **A keeper PR removes its legacy source in the same PR** (CLAUDE.md pruning protocol: `git rm` + `legacy/migrated/<keeper-id>.md`), and such a PR may be built by a run. Such a run must still be able to read and `git rm` legacy source when its scope names a `legacy/` path; say how (e.g. widen the sparse set from the scope) rather than leaving it to break.

## Acceptance
- [ ] An issue worktree contains no `legacy/` tree other than `legacy/migrated/`, and still does not after a branch switch inside it — or after the worktree is reused on resume.
- [ ] The operator's main checkout is not made sparse.
- [ ] Repo-wide searches inside a run no longer traverse it.
- [ ] The sentinel behaviour is unaffected for anyone running from the main checkout.
- [ ] Guard: the pruning protocol (`git rm` + `legacy/migrated/<keeper-id>.md`) still works from the main checkout.
- [ ] Regression test asserting the worktree has no `legacy/`; reddens at the merge-base.

Refs ADR-059 §2, ADR-002, `scripts/lib/call-graph.sh:55-60`.
