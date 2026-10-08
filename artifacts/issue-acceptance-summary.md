## issue-acceptance — fail

- The SPEC-2 regression assertion (`zbuild_worktree_enter create returns 0`) passes on old code — the acceptance-gate confirmed it as tautological — so the test does not demonstrate that the `zbuild_worktree_enter` changes are required for SPEC-2 to pass, leaving R-6 unmet.

- NOT MET: R-6: regression test asserting the worktree has no `legacy/`
- NOT MET: reddens at the merge-base — the SPEC-2 gating assertion (`[#1802/SPEC-2] zbuild_worktree_enter create returns 0`) passes on the old code unchanged
- NOT MET: the `_assert_sparse` calls that test the actual sparse behaviour use a different tag (`[#1802/SPEC-2 create]`) and were not recognised by negctl as the SPEC-2 assertion
