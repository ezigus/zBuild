# spec-coverage checkpoint

## Files read
- /home/runner/work/_temp/zbuild-state/artifacts/design.md — 7 SPECs covering sparse-checkout via _zbuild_worktree_apply_sparse; zbuild_worktree_include_legacy_path for keeper PRs; ADR-059 amendment
- /home/runner/work/_temp/zbuild-state/artifacts/requirements.json — 6 requirements R-1 through R-6

## Conclusions reached

R-1 (worktree has no legacy/ except migrated/, survives branch switch and resume): COVERED by SPEC-1, SPEC-2, SPEC-3, SPEC-4.
R-2 (main checkout not made sparse): COVERED by SPEC-5 (extensions.worktreeConfig isolates per-worktree config; main core.sparseCheckout absent/false asserted).
R-3 (repo-wide searches no longer traverse legacy/): COVERED by SPEC-1 and SPEC-2 — files absent from worktree means no traversal.
R-4 (sentinel behaviour unaffected for main checkout users): COVERED by SPEC-5 — main checkout not sparse, so all legacy/ files including sentinel remain.
R-5 (pruning protocol still works from main checkout): COVERED by SPEC-5 — main checkout not sparse, git rm on legacy/ source works.
R-6 (regression test, reddens at merge-base): COVERED by SPEC-1 through SPEC-4, all backed by tests/unit/worktree-sparse-legacy-test.sh.

## Verdict
All 6 requirements fully covered. No uncovered gaps found.
