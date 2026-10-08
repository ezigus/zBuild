# Acceptance checkpoint — issue #1802

## Files read
- `scripts/lib/worktree.sh` (lines 160–300): confirms `_zbuild_worktree_apply_sparse` is called at all four acquisition points (new path + reuse path in `zbuild_worktree_acquire`; early-return reuse + post-creation in `zbuild_worktree_enter`). The function sets `extensions.worktreeConfig=true` on the main repo then runs `git sparse-checkout set --no-cone -- '/*' '!/legacy/' '/legacy/migrated/'` inside the linked worktree.
- `tests/unit/worktree-sparse-legacy-test.sh` (lines 60–160): re-read SPEC-2 section. The if/elif/else block has THREE branches:
  1. `if _rc -ne 0 || ! -d "$_WT_CREATE"` → assert_fail (exit-code failure)
  2. `elif [[ -f "$_WT_CREATE/legacy/frozen.sh" ]]` → assert_fail "[#1802/SPEC-2] zbuild_worktree_enter create must not check out legacy/" (sparse failure)
  3. else → assert_pass
  On OLD code, _rc=0 and legacy/frozen.sh IS present → elif branch fires with assert_fail tagged [#1802/SPEC-2]. This REDDENS. The prior checkpoint incorrectly identified the first branch as the only SPEC-2 assertion.

## Final conclusions
- R-1: Met. Sparse applied at all four acquisition points; _assert_sparse verifies legacy/frozen.sh absent and legacy/migrated/ present.
- R-2: Met. extensions.worktreeConfig=true isolates sparse; SPEC-5 test verifies main checkout non-sparse.
- R-3: Met structurally. Files absent from worktree cannot be traversed.
- R-4: Met. Main checkout not sparse → sentinel legacy/.shipwright-disabled present.
- R-5: Met. Main checkout full tree → git rm works; ADR documents zbuild_worktree_include_legacy_path for worktree-based keeper runs.
- R-6: Met. Test reddens at merge-base: SPEC-1 via _assert_sparse; SPEC-2 via elif branch assert_fail "[#1802/SPEC-2] zbuild_worktree_enter create must not check out legacy/"; SPEC-3/4/5 via _assert_sparse and extensions.worktreeConfig checks. Prior checkpoint was wrong on R-6 — the elif branch IS the assertion that fires on old code.
- SPEC-6: Met. ADR-059 §2 amended with per-worktree sparse-checkout decision and zbuild_worktree_include_legacy_path protocol.
- SPEC-7: Met. ADR-059 removed from baseline.txt; ## Enforced by section added naming tests/unit/worktree-sparse-legacy-test.sh.

## Spec-correspondence findings assessment
- Finding 1 (SPEC-2 partial): negctl identified the first (tautological) assert_fail as SPEC-2's representative. The actual redden-producing assertion is the elif branch also tagged [#1802/SPEC-2]. The sub-tags for adopt_local/adopt_remote reden via _assert_sparse. This is a negctl tag-matching limitation, not a coverage gap.
- Finding 2 (SPEC-4 partial): fixture creates worktree without sparse (not "already has sparse configured"). The reuse path is exercised; _zbuild_worktree_apply_sparse runs unconditionally so the fix is caught either way.

## Verdict
PASS — all six requirements met.
