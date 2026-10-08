# spec-correspondence checkpoint

## Files read
- design.md: defines _assert_sparse helper (checks legacy/frozen.sh absent + legacy/migrated/tombstone.md present); fixture creates one non-migrated legacy file (legacy/frozen.sh) and one migrated file (legacy/migrated/tombstone.md).
- tests/unit/worktree-sparse-legacy-test.sh (full file): confirms _assert_sparse checks both exclusion and inclusion; confirms SPEC-3 only checks exclusion (no _assert_sparse call); confirms SPEC-4 fixture creates a NON-sparse worktree while requirement says "already has sparse-checkout configured".

## Conclusions reached

SPEC-1: CORRESPONDS — assertion checks rc=0, worktree created, and calls _assert_sparse which checks both frozen.sh absent and tombstone.md present.

SPEC-2: CORRESPONDS — all three modes tested (create, adopt_local, adopt_remote), each with rc=0 check and _assert_sparse.

SPEC-3: CORRESPONDS — requirement is about exclusion surviving branch switch (absence constraint only); assertion checks legacy/frozen.sh absent after git checkout; "other than paths under legacy/migrated/" is a permission clause, not a requirement to have content there.

SPEC-4: PARTIAL — assertion tests the reuse path (right code path) but fixture starts without sparse; requirement says "already has sparse-checkout configured", assertion starts without sparse. A bug where zbuild skips re-apply when sparse already set would not be caught.

SPEC-5: CORRESPONDS — checks all three properties: core.sparseCheckout absent/false, extensions.worktreeConfig=true, and legacy/frozen.sh still in main checkout.

## Still unresolved
Nothing — all 5 SPECs judged. Final output written.
