# Performance lens checkpoint — issue #1802

## Files read
- `scripts/lib/worktree.sh` — full file. Key new code: `_zbuild_worktree_apply_sparse` (lines 295-302) and `zbuild_worktree_include_legacy_path` (lines 308-313). Called at 4 sites: acquire-reuse (181), acquire-new (205), enter-reuse (244), enter-new (286).

## Conclusions reached
1. **Net positive**: excluding legacy/ (~725 files, 12.1 MB, 50% of tree) from every issue worktree eliminates traversal cost on every agent search. Benefit is per-agent-turn and compounds over an issue's lifetime.
2. **Redundant git config write on resume**: `git -C "$repo_root" config extensions.worktreeConfig true` is called on every acquisition including the reuse path. `extensions.worktreeConfig` only needs to be set once per repo; re-writing the same value on every resume is O(n) where O(1) suffices. Cost is low (~1-5ms per git config write) but is unnecessary overhead on the hot resume path. Introduced by this change.
3. **`git sparse-checkout set` re-applies on every reuse**: Explicitly required by SPEC-4 and issue constraint ("A reused worktree must get the exclusion too"). This is correct for correctness; no performance issue to flag beyond the above.
4. **`--no-cone` without `--sparse-index`**: git index still tracks all 725 legacy/ files; index scans happen for every git operation. This is an existing git limitation — cone mode cannot express negation patterns — and is the correct choice for this use case.
5. No O(n^2) or worse complexity introduced. No blocking I/O in loops. No unnecessary allocations.

## Score estimate: 9 — one low-severity introduced issue (redundant git config write on resume)

## What I would do next if stopping
- Confirm `zbuild_worktree_acquire` is not called in a loop (it isn't — called once per run before first stage dispatch).
- Check test file for any performance anti-patterns (unlikely to matter for a unit test).
