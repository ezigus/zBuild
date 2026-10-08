# spec-coverage checkpoint

## Files read
- /home/runner/work/_temp/zbuild-state/artifacts/design.md — current design: 7 SPECs covering worktree sparse-checkout implementation; SPEC-1 describes observable behavior (zbuild_worktree_acquire called with run_id + repo containing legacy/ → returns 0 + linked worktree with no legacy/ except migrated/)
- /home/runner/work/_temp/zbuild-state/artifacts/requirements.json — 6 requirements R-1 through R-6

## Conclusions reached

R-1 (worktree has no legacy/ except migrated/, survives branch switch and resume): COVERED by SPEC-1 (create via acquire), SPEC-2 (enter all modes), SPEC-3 (branch switch), SPEC-4 (resume/reuse path).
R-2 (main checkout not made sparse): COVERED by SPEC-5 — asserts core.sparseCheckout absent/false in main checkout; extensions.worktreeConfig provides isolation.
R-3 (repo-wide searches no longer traverse legacy/): COVERED by SPEC-1 and SPEC-2 — files absent from worktree working directory cannot be traversed by find/grep.
R-4 (sentinel behaviour unaffected for main checkout): COVERED by SPEC-5 — main checkout remains non-sparse so all legacy/ files including sentinel remain present.
R-5 (pruning protocol still works from main checkout): COVERED by SPEC-5 — main checkout not sparse means git rm on legacy/ source works; R-5 is explicitly scoped to main checkout.
R-6 (regression test, reddens at merge-base): COVERED by SPEC-1 through SPEC-4 all backed by tests/unit/worktree-sparse-legacy-test.sh; reddening at merge-base is a verification-time check.

design-gate finding 1: SPEC-1 now describes an observable behavior (input + what happens). Finding is addressed by the current design.

## Verdict
All 6 requirements fully covered. No uncovered gaps.
