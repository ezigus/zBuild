# Plan Checkpoint — Issue #1802

## Files Read
- `scripts/lib/worktree.sh` — `zbuild_worktree_acquire` (line 154-206) uses plain `git worktree add --detach`; `zbuild_worktree_enter` (line 227-285) uses `git worktree add` with branch. Reuse paths return early at line 180-183 (`zbuild_worktree_acquire`) and line 238-243 (`zbuild_worktree_enter`). Fix must apply sparse config at BOTH new-creation AND reuse return paths in each function.
- `tests/unit/worktree-location-test.sh` — existing tests SPEC-1 through SPEC-14. New sparse test goes in a new file.
- `tests/unit/legacy-e1-tombstone-test.sh` — asserts `$REPO_ROOT/legacy/migrated/e-1.md` exists (line 13-14). Fix must keep `legacy/migrated/` materialised.
- `scripts/lib/call-graph.sh:55-60` — `--exclude-dir=legacy` pattern to follow.
- `docs/adr/ADR-059-issue-vs-run-keying.md` — §2 is "why the worktree belongs to the issue". Currently in enforcement baseline. This fix amends §2 to add sparse-checkout statement.
- `scripts/lib/lint-adr-enforced-by.sh` — if `## Enforced by` added to ADR-059, must also remove from `config/adr-enforcement-baseline.txt`. Section just needs at least one real file path.
- `config/adr-enforcement-baseline.txt` — lists both `ADR-002-legacy-import-strategy.md` and `ADR-059-issue-vs-run-keying.md`.

## Conclusions
1. Implementation: Add `_zbuild_worktree_apply_sparse <wt> <repo_root>` helper that:
   - Sets `extensions.worktreeConfig = true` on the main repo (allows per-WT sparse file)
   - Runs `git -C "$wt" sparse-checkout set --no-cone '/*' '!/legacy/' '/legacy/migrated/'`
   - Safe: `extensions.worktreeConfig` doesn't make the main checkout sparse; per-WT sparse-checkout does not touch the main checkout's `core.sparseCheckout`
2. Call `_zbuild_worktree_apply_sparse` at all 4 return points (2 in acquire, 2 in enter)
3. Add `zbuild_worktree_include_legacy_path <wt> <path>` to widen sparse set for keeper PRs
4. New test: `tests/unit/worktree-sparse-legacy-test.sh` — asserts no legacy/ except migrated/, reuse retains exclusion, main checkout not sparse
5. Amend ADR-059 §2 + add `## Enforced by` section + remove from baseline

## Plan ready to emit
