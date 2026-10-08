# Acceptance checkpoint — issue #1802

## Files read
- `scripts/lib/worktree.sh` (lines 160–300): confirms `_zbuild_worktree_apply_sparse` is called at all four acquisition points (new path + reuse path in `zbuild_worktree_acquire`; early-return reuse + post-creation in `zbuild_worktree_enter`). The function sets `extensions.worktreeConfig=true` on the main repo then runs `git sparse-checkout set --no-cone -- '/*' '!/legacy/' '/legacy/migrated/'` inside the linked worktree.
- `tests/unit/worktree-sparse-legacy-test.sh` (lines 85–134): confirmed the SPEC-2 tautology. The first assertion under SPEC-2 create, adopt_local, and adopt_remote is `assert_pass "[#1802/SPEC-2] zbuild_worktree_enter <mode> returns 0"` — this passes on old code because `zbuild_worktree_enter` returned 0 before the change. The actual sparse check uses `_assert_sparse "#1802/SPEC-2 create"` which produces tags `[#1802/SPEC-2 create]`, not `[#1802/SPEC-2]` — so negctl matched the tautological assertion as the SPEC-2 representative.

## Conclusions
- R-1: Met. Sparse applied at every acquisition point; persistent sparse survives branch switch.
- R-2: Met. `extensions.worktreeConfig=true` isolates sparse config; SPEC-5 verifies main checkout non-sparse.
- R-3: Met structurally. Absent files cannot be traversed.
- R-4: Met. Main checkout not sparse → sentinel present.
- R-5: Met. SPEC-5 verifies `legacy/frozen.sh` exists in main checkout → `git rm` works; ADR documents `zbuild_worktree_include_legacy_path` for worktree-based keeper runs.
- R-6: UNMET. The SPEC-2 gating assertion is tautological. The test file does reden overall for SPEC-1/3/4/5, but the assertion negctl identified as representing SPEC-2 (`zbuild_worktree_enter create returns 0`) passes on old code.

## Verdict
FAIL on R-6.
