# Red-team lens checkpoint

## Files read
- scripts/lib/worktree.sh — full implementation including new `_zbuild_worktree_apply_sparse` and `zbuild_worktree_include_legacy_path`
- tests/unit/worktree-sparse-legacy-test.sh — full test file
- design.md — design decisions and SPEC contract

## Key conclusions reached

### Finding 1 (HIGH → medium): Option injection in `zbuild_worktree_include_legacy_path`
`git -C "$wt" sparse-checkout add "$path"` has no `--` separator. If `$path`
begins with `--` (e.g., `--cone`), git treats it as a flag, not a path.
`--cone` specifically switches the sparse-checkout mode from no-cone to cone,
which cannot express negation patterns — it would silently destroy the
`!/legacy/` exclusion for that worktree. Paths derived from keeper-PR issue
scope data could be adversarially constructed. The companion `_zbuild_worktree_apply_sparse`
does use `-- '/*' '!/legacy/' '/legacy/migrated/'` correctly; only the add function is affected.
INTRODUCED by this change.

### Finding 2 (low): `extensions.worktreeConfig=true` permanently written to main-checkout config
`git -C "$repo_root" config extensions.worktreeConfig true` writes to
`$repo_root/.git/config` and is never reverted, even after all linked worktrees
are removed. The issue's acceptance criteria say "The operator's main checkout
is not made sparse" but do not say its `.git/config` is left unchanged.
A repo owner who had deliberately set `extensions.worktreeConfig=false` to
prevent per-worktree isolation would have that overridden silently.
INTRODUCED by this change.

### Finding 3 (low/coverage): SPEC-4 test pre-condition mismatch with spec text
SPEC-4 spec says "a linked worktree that already has sparse-checkout configured".
Test fixture creates a plain worktree with NO sparse at all. The test verifies
that acquire re-applies sparse on the reuse path starting from a fully materialised
tree, but does not verify that an existing sparse pattern is correctly *overwritten*
(not merged with) the new pattern. spec-correspondence already flagged this;
from a red-team view the gap means a future git version that merges patterns on
`sparse-checkout set` (instead of replacing) would not be caught.
INTRODUCED by this change.

## Status: complete — emitting JSON
