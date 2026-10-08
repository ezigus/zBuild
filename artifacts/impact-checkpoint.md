# Impact Checkpoint — Issue #1802

## Files read and what they told me

- `design.md`: Change adds `_zbuild_worktree_apply_sparse` and `zbuild_worktree_include_legacy_path` to `worktree.sh`; calls the former at all return points of `zbuild_worktree_acquire` and `zbuild_worktree_enter`. Removes ADR-059 from enforcement baseline; adds `## Enforced by` section to ADR-059 naming 3 test files.
- `plan.json`: 3 steps — write test first, implement in worktree.sh, amend ADR-059 + remove from baseline.
- `scripts/lib/worktree.sh`: Existing functions `zbuild_worktree_acquire` (line ~154) and `zbuild_worktree_enter` (line ~227). Both are being modified to call `_zbuild_worktree_apply_sparse`. 
- `config/adr-enforcement-baseline.txt`: ADR-059 is at line 62. Will be removed.
- `docs/adr/ADR-059-issue-vs-run-keying.md`: Long ADR, no `## Enforced by` section yet. Will get one naming 3 test files.
- `tests/unit/lint-adr-enforced-by-test.sh`: Has A7 which runs real lint against repo. Passes after change because ADR-059 gets Enforced-by section and is removed from baseline.

## Grep findings

- Files calling `zbuild_worktree_acquire` or `zbuild_worktree_enter` (besides worktree.sh itself):
  - All test files in scope: cleanup-cli-e2e-test.sh, worktree-ownership-test.sh, intake-branch-held-diagnostic-test.sh, worktree-location-test.sh
  - `tests/unit/goal-identity-test.sh` — reference is comment-only, not a call
  - `plugins/agent/intake/lib/branch-names.sh` — reference is comment-only, not a call
  - `docs/adr/ADR-052-engine-owned-run-worktree.md` — docs reference
  - `core/pipeline/runner.sh` — IN SCOPE, line 1645 calls zbuild_worktree_acquire

- Files referencing `legacy/migrated/`: only `tests/unit/legacy-e1-tombstone-test.sh` (in scope)
- No files reference `extensions.worktreeConfig`, `sparse-checkout` patterns, or the new symbols being added.

## Conclusions

All test files that directly call the modified functions are already in scope. The new symbols have no existing callers (new API). The ADR-059 baseline removal has no test that pins the count or names of baseline entries. No scope gaps found.

## If stopping now

Verdict: complete, missing=[]
