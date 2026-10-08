## issue-acceptance — pass

- All six requirements are met — sparse-checkout is applied at every acquisition point (R-1), `extensions.worktreeConfig` isolates per-worktree config leaving the main checkout non-sparse (R-2), absent files cannot be traversed (R-3), main checkout remains fully materialised so the sentinel and `git rm` both work (R-4, R-5), and the regression test contains assertions tagged `[#1802/SPEC-2]` that fire on old code via the `elif` branch and `_assert_sparse` calls, redening at the merge-base (R-6).

- every requirement the issue states is met by the change
