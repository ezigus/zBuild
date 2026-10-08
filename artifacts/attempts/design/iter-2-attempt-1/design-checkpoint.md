# design-checkpoint

## Files read and key findings

- `scripts/lib/worktree.sh` — `zbuild_worktree_acquire` (lines 154-206) and `zbuild_worktree_enter` (lines 227-285) each have a reuse return and a new-tree creation return. Both need `_zbuild_worktree_apply_sparse` called at both exits. No sparse-checkout machinery exists today.
- `docs/adr/ADR-059-issue-vs-run-keying.md` — §2 is the "why the worktree belongs to the issue" section. It has no `## Enforced by` section and is currently in the baseline exemption list. The ADR notes at the end that `legacy/` is materialised once per issue instead of once per run (#1802), but does not yet document the sparse-checkout exclusion.
- `config/adr-enforcement-baseline.txt` — ADR-059 is listed on line 62. Must be removed once the ADR gains its `## Enforced by` section.
- `tests/unit/worktree-location-test.sh` — calls `zbuild_worktree_enter` on a real git repo (SPEC-9–13). No legacy/ in test repos, so new sparse-checkout code runs silently there without breaking anything. In scope as a file that exercises the changed functions.
- `tests/integration/worktree-ownership-test.sh` — calls `zbuild_worktree_acquire`; same reasoning.
- `tests/unit/legacy-e1-tombstone-test.sh` — referenced in ADR-059 plan's `## Enforced by` section.
- `core/pipeline/runner.sh:1645` — the live engine call: `zbuild_worktree_acquire "$wt_key" "$ZBUILD_MAIN_REPO_ROOT"`. No change needed there; sparse-checkout is applied transparently.

## Conclusions reached

- The implementation is entirely in `scripts/lib/worktree.sh` + new test file.
- `extensions.worktreeConfig=true` must be set on the main repo BEFORE writing per-worktree sparse-checkout; without it, `git sparse-checkout set` writes a shared file that would sparsify all worktrees including the main checkout.
- Pattern `/* !/legacy/ /legacy/migrated/` in no-cone mode is correct.
- WIRING = `scripts/lib/worktree.sh` (the call sites to `_zbuild_worktree_apply_sparse` live in the same file as the implementation).
- No existing tests break (test repos don't contain legacy/).
- 6 SPECs: SPEC-1 through SPEC-4 are [code]; SPEC-5 and SPEC-6 are [no-code].
- R-4 (sentinel unaffected) and R-5 (pruning protocol) are structural properties of `extensions.worktreeConfig` — covered by SPEC-4's test that main checkout stays non-sparse.

## Iteration 3 additions

- design-gate finding 1: SPEC-1/2/4 used "contains no files" (file-state, not code behavior). Fix: rewrite to name the action and observable outcome.
- Grep confirms no additional callers of zbuild_worktree_acquire/enter. Scope complete.

## Writing design.md now (iteration 3).
