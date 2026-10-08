## Checkpoint — worktree-sparse-legacy-test.sh (#1802) — iteration 2 COMPLETE

### Files written

1. `tests/unit/worktree-sparse-legacy-test.sh` — created (SPEC-1 through SPEC-5); SPEC-2 fixed in iteration 2
2. `docs/adr/ADR-059-issue-vs-run-keying.md` — amended §2 with sparse-checkout text + added `## Enforced by` section (SPEC-6, SPEC-7)
3. `config/adr-enforcement-baseline.txt` — removed `ADR-059-issue-vs-run-keying.md` line (SPEC-7)

### Fix in iteration 2

The SPEC-2 gating assertion was tautological: it checked only exit code (which passes on
old code). Fixed by restructuring the create-mode block so the `[#1802/SPEC-2]` assertion
directly tests whether `legacy/frozen.sh` is absent from the worktree. On old code,
zbuild_worktree_enter succeeds but doesn't apply sparse-checkout → frozen.sh is present →
assert_fail → test fails on old code (non-tautological). After the fix → frozen.sh absent →
assert_pass.

Also changed adopt_local / adopt_remote exit-code assertions from bare `[#1802/SPEC-2]`
to sub-tags `[#1802/SPEC-2 adopt_local]` / `[#1802/SPEC-2 adopt_remote]` so there is
exactly one primary SPEC-2 assertion.

### Verification

- shellcheck passes on the updated test file

### SPEC coverage (all 7 complete)

- SPEC-1: acquire (new) — rc=0 + sparse assertions
- SPEC-2: enter (create/adopt_local/adopt_remote) — primary [#1802/SPEC-2] assertion checks sparse outcome (non-tautological)
- SPEC-3: git checkout inside worktree — sparse persists after branch switch
- SPEC-4: reuse path (resume) — sparse re-applied even if worktree already exists
- SPEC-5: main checkout non-sparse — core.sparseCheckout absent/false, extensions.worktreeConfig=true
- SPEC-6: ADR-059 §2 amended with sparse-checkout decision and widening protocol
- SPEC-7: ADR-059 removed from baseline, ## Enforced by section added
