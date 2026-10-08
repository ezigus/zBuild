# Correctness Lens Checkpoint

## Files read
- scripts/lib/worktree.sh: full file read. Key: _zbuild_worktree_apply_sparse sets
  extensions.worktreeConfig on repo_root then calls `git -C "$wt" sparse-checkout set`.
  zbuild_worktree_include_legacy_path calls `git -C "$wt" sparse-checkout add "$path"`.

## Observations so far

### worktree.sh correctness
1. `_zbuild_worktree_apply_sparse` suppresses all errors with `2>/dev/null` — if
   git sparse-checkout fails (e.g. old git version), the caller only gets rc=5 with
   no message. Minor, pre-existing style issue.
2. `zbuild_worktree_include_legacy_path` calls `sparse-checkout add` with an
   unsanitized `$path` argument. If a caller passes a path with shell metacharacters
   or absolute path outside legacy/, git would accept it. Not a security issue
   (internal API only), but a logic concern — the function claims to be for legacy/
   paths but does not validate the path starts with "legacy/".
3. `_zbuild_worktree_apply_sparse` does NOT check if wt is actually a registered
   git worktree before running sparse-checkout on it. If called on a non-worktree
   path, git sparse-checkout would fail with rc=5 (but error suppressed).
4. SPEC-4 fixture: the test manually creates a worktree via `git worktree add --detach`
   (no sparse), then calls `zbuild_worktree_acquire spec4-resume "$_R"`. However,
   zbuild_worktree_acquire derives the path via `zbuild_worktree_path "spec4-resume"`,
   which under ZBUILD_WORKTREE_ROOT produces "$TEST_TEMP_DIR/wt/spec4-resume".
   The manually created worktree is at "$_WT4_PATH" = "$TEST_TEMP_DIR/wt/spec4-resume".
   These match, so this should work. But the test verifies the sparse is applied by
   checking "$_WT4_PATH/legacy/frozen.sh" absent. This is correct logic.

## Still to check
- tests/unit/worktree-sparse-legacy-test.sh in detail
- SPEC-4 pre-condition: the issue says "already has sparse-checkout configured" but
  fixture creates WITHOUT sparse — spec-correspondence already flagged this.
- zbuild_worktree_enter: the "adopt_local" path in tests uses `cd "$_R" &&` but
  zbuild_worktree_enter calls `git rev-parse --show-toplevel` (no -C flag), so it
  relies on the current directory being inside the repo.

## Completed analysis

### worktree.sh findings
1. `_zbuild_worktree_apply_sparse` silences ALL stderr (2>/dev/null) unlike rest of file
   which captures git errors and prints them. Returns rc=5 with no diagnostic. INTRODUCED.
2. `zbuild_worktree_include_legacy_path` has no guard that $path starts with "legacy/".
   Contract says "legacy source", but any path accepted. INTRODUCED.
3. Order of operations: sets extensions.worktreeConfig first, then sparse-checkout set. CORRECT.
4. Pattern '/* !/legacy/ /legacy/migrated/' is correct gitignore-style for no-cone mode. CORRECT.
5. zbuild_worktree_enter uses CWD-derived repo_root -- pre-existing, not introduced.

### test file findings  
6. SPEC-4 fixture creates a worktree WITHOUT sparse-checkout configured. Requirement says
   "already has sparse-checkout configured". Code works for both cases (set replaces patterns)
   but test doesn't verify the actual scenario specified. INTRODUCED, already flagged by spec-correspondence.

### ADR/config
7. ADR-059 amendment correctly describes the implementation.
8. Removal from adr-enforcement-baseline.txt is correct (ADR now has Enforced by section).

CONCLUSION: Score 7. Core logic correct. Issues: silent error handling, no path validation in
include_legacy_path, SPEC-4 pre-condition mismatch.
