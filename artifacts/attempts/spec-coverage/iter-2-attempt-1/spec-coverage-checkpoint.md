# spec-coverage checkpoint

## Files read
- /home/runner/work/_temp/zbuild-state/cycle-design_verify_cycle/iter-2/feedback/design.txt — revised design (iter-2): 7 SPECs, SPEC-1 now describes observable outcome ("after zbuild_worktree_acquire, the linked worktree contains no files under legacy/ except those under legacy/migrated/")
- /home/runner/work/_temp/zbuild-state/artifacts/requirements.json — 6 requirements R-1 through R-6

## Conclusions reached

R-1 (worktree has no legacy/ except migrated/, survives branch switch and resume): COVERED by SPEC-1, SPEC-2, SPEC-3, SPEC-4.
R-2 (main checkout not made sparse): COVERED by SPEC-5 (extensions.worktreeConfig isolates per-worktree config; main core.sparseCheckout absent/false asserted).
R-3 (repo-wide searches no longer traverse legacy/): COVERED by SPEC-1 and SPEC-2 — files absent from worktree means no traversal.
R-4 (sentinel behaviour unaffected for main checkout users): COVERED by SPEC-5 — main checkout not sparse, all legacy/ files including sentinel remain accessible.
R-5 (pruning protocol still works from main checkout): COVERED by SPEC-5 — main checkout not sparse, git rm on legacy/ source works; SPEC-6 names zbuild_worktree_include_legacy_path for worktree-scoped keeper PRs.
R-6 (regression test, reddens at merge-base): COVERED by SPEC-1 through SPEC-4, all backed by tests/unit/worktree-sparse-legacy-test.sh.

## Verdict
All 6 requirements fully covered. No uncovered gaps found.
Design-gate finding 1 addressed by iter-2 revision: SPEC-1 now states observable outcome, not file contents.
