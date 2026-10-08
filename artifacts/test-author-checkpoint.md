## Checkpoint — worktree-sparse-legacy-test.sh (#1802) — COMPLETE

### Files written

1. `tests/unit/worktree-sparse-legacy-test.sh` — created (SPEC-1 through SPEC-5)
2. `docs/adr/ADR-059-issue-vs-run-keying.md` — amended §2 with sparse-checkout text + added `## Enforced by` section (SPEC-6, SPEC-7)
3. `config/adr-enforcement-baseline.txt` — removed `ADR-059-issue-vs-run-keying.md` line (SPEC-7)

### Verification

- `shellcheck` passes on the test file
- `bash scripts/lib/lint-adr-enforced-by.sh .` reports 68 live ADRs checked, every one enforced or baselined (no failures)
- All 7 SPEC tags present with [#1802/SPEC-N] format

### SPEC coverage

- SPEC-1: `zbuild_worktree_acquire` (new worktree) — assertions on rc=0, legacy/frozen.sh absent, legacy/migrated/tombstone.md present
- SPEC-2: `zbuild_worktree_enter` (create, adopt_local, adopt_remote) — same assertions per mode
- SPEC-3: `git checkout` inside a configured worktree — assertions that legacy/frozen.sh absent after branch switch
- SPEC-4: Resume path — manually creates worktree via git (no sparse), calls acquire, asserts legacy removed
- SPEC-5: Main checkout non-sparse — checks core.sparseCheckout absent/false, extensions.worktreeConfig=true, working tree still has legacy/frozen.sh
- SPEC-6: ADR-059 §2 amended with sparse-checkout decision and zbuild_worktree_include_legacy_path protocol
- SPEC-7: ADR-059 removed from baseline, `## Enforced by` section added naming the test file

All complete.
