# Build checkpoint — issue #1802 iteration 1

## Files read
- tests/unit/worktree-sparse-legacy-test.sh (200 lines): full acceptance test — SPEC-1 through SPEC-5 test acquire/enter produce sparse worktrees, branch-switch survives, reuse path re-applies, main checkout stays non-sparse
- scripts/lib/worktree.sh (449 lines): worktree library — needs _zbuild_worktree_apply_sparse and zbuild_worktree_include_legacy_path added, plus calls in zbuild_worktree_acquire (both reuse and new-creation paths) and zbuild_worktree_enter (reuse path + after git worktree add)
- docs/adr/ADR-059-issue-vs-run-keying.md: already amended by test-author with §2 sparse docs and ## Enforced by section — SPEC-6 done
- config/adr-enforcement-baseline.txt: ADR-059-issue-vs-run-keying.md is NOT in the file — SPEC-7 done

## Conclusions
- SPEC-6 and SPEC-7 already satisfied by test-author stage changes
- SPEC-1..5 require code changes to scripts/lib/worktree.sh
- Need to add: _zbuild_worktree_apply_sparse, zbuild_worktree_include_legacy_path
- Need to call _zbuild_worktree_apply_sparse at: acquire reuse path, acquire new path, enter reuse path, enter after git worktree add

## What's next
- Edit scripts/lib/worktree.sh to add functions and calls
- Run the test to verify
