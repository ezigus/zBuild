# Security lens checkpoint — issue #1802

## Files examined
- diff.patch (in-prompt): the full change
- Examining scripts/lib/worktree.sh in repo for context

## Conclusions so far

### _zbuild_worktree_apply_sparse (internal, underscore prefix)
- Takes `wt` (worktree path) and `repo_root` from callers inside worktree.sh
- Both are engine-provided values per repo rules; not user input
- Sparse pattern is a literal string, no variable substitution — no injection
- `git -C "$wt"` uses double-quoted variable — no word-splitting injection
- `git -C "$repo_root" config extensions.worktreeConfig true` modifies main repo config — acceptable, engine-controlled inputs only
- `2>/dev/null` suppresses stderr but `|| return 5` propagates failures — callers fail loudly

### zbuild_worktree_include_legacy_path (public API, no callers in diff)
- Takes `path` from caller — no validation whatsoever
- Passes directly to `git -C "$wt" sparse-checkout add "$path"` 
- git sparse-checkout patterns support negation (`!`) and wildcards (`*`)
- A caller passing `/legacy/` would RE-INCLUDE all of legacy/ defeating the exclusion
- A caller passing `/*` would disable the exclusion entirely
- This is a new public function with no callers yet — but designed for future use by keeper PRs
- The design says keeper PRs call it with a legacy source path — that path could come from templates/manifests (system boundaries per repo rules)
- No check that path starts with `legacy/` or that it doesn't contain git pattern syntax

## Key finding
zbuild_worktree_include_legacy_path accepts an unvalidated `path` that git interprets as a sparse-checkout pattern. A value like `/legacy/` or `/*` would defeat the exclusion that this entire change implements. The function should validate the path begins with `legacy/` and does not start with `!` or contain wildcards beyond what is legitimate for a file path.

## Resolved
- No existing callers of zbuild_worktree_include_legacy_path in the diff or visible repo code
- wt/repo_root are engine-provided per repo rules; path traversal on those is lower risk
- _zbuild_worktree_apply_sparse: pattern is a literal string, no injection; failures propagate via rc=5

## Final findings
1. zbuild_worktree_include_legacy_path: unvalidated path, can be pattern that re-includes legacy/ — medium, introduced
2. 2>/dev/null suppresses diagnostics for sparse failures — low, introduced
