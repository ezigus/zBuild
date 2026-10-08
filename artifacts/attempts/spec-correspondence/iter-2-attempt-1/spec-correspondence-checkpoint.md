# spec-correspondence checkpoint (updated run 2)

## Files read
- design.md (prior run): defines _assert_sparse helper; fixture has legacy/frozen.sh and legacy/migrated/tombstone.md.
- tests/unit/worktree-sparse-legacy-test.sh (this run, full): key findings:
  - Line 86: primary SPEC-2 assert_pass is "[#1802/SPEC-2] zbuild_worktree_enter create: legacy/frozen.sh absent from worktree" — checks sparse exclusion, NOT tautological (the tautological string "zbuild_worktree_enter create returns 0" does NOT appear in current file)
  - Lines 90-116: adopt_local and adopt_remote tests present but tagged [#1802/SPEC-2 adopt_local] / [#1802/SPEC-2 adopt_remote] — not the plain [#1802/SPEC-2] tag, so negctl did not recognize them as the SPEC-2 assertion
  - SPEC-2 assertion block provided in prompt covers create mode ONLY
  - SPEC-3 has no _assert_sparse call — only checks frozen.sh absence directly (no tombstone check)
  - SPEC-4 fixture creates worktree WITHOUT sparse; requirement says "already has sparse-checkout configured"

## Revised conclusions

SPEC-1: CORRESPONDS
SPEC-2: PARTIAL — provided assertion covers only create mode; requirement says all three modes; other modes tested in file but under sub-tags not recognized as SPEC-2's assertion
SPEC-3: CORRESPONDS — requirement is exclusion-only (no migrated/ content requirement); absence check is sufficient
SPEC-4: PARTIAL — fixture has no sparse pre-configured; requirement says "already has sparse-checkout configured"
SPEC-5: CORRESPONDS

## Findings
- acceptance-gate finding 1: nothing to do (judge role only; current file's SPEC-2 assertion is not tautological)
- issue-acceptance finding 1: nothing to do (cannot change files; reflected in PARTIAL judgment for SPEC-2)
- issue-acceptance finding 2: nothing to do (same as above)
- issue-acceptance finding 3: reflected in PARTIAL judgment for SPEC-2
