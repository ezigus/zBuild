# Design: Exclude legacy/ from issue worktrees via sparse-checkout (#1802)

## Summary

**Goal:** Apply per-worktree sparse-checkout to every issue worktree so `legacy/` is absent (except `legacy/migrated/`), eliminating the ~50% tree overhead every repo-wide agent search currently pays.

**Context:** `legacy/` is a frozen, never-executed reference copy (~50% of the tree). Every agent running inside an issue worktree traverses it at full cost. ADR-059 §2 already notes that `legacy/` is materialised once per issue instead of once per run (#1802); this issue writes the mechanism that makes that note true.

**Decision:** Add `_zbuild_worktree_apply_sparse <wt> <repo_root>` to `scripts/lib/worktree.sh`. It sets `extensions.worktreeConfig=true` on the main repo config (enabling per-worktree isolation), then runs `git -C "$wt" sparse-checkout set --no-cone -- '/*' '!/legacy/' '/legacy/migrated/'` inside the linked worktree. Call it at every return point of both `zbuild_worktree_acquire` (new creation and reuse) and `zbuild_worktree_enter` (all three modes, new creation and reuse). Also ship `zbuild_worktree_include_legacy_path <wt> <path>` for keeper PRs that must read or `git rm` a specific legacy source before migration. Amend ADR-059 §2 to document the decision and add the required `## Enforced by` section; remove ADR-059 from `config/adr-enforcement-baseline.txt`.

**Why `extensions.worktreeConfig`:** Without it, `git sparse-checkout set` writes `$repo/.git/info/sparse-checkout`, which is shared across all worktrees including the main checkout — making every linked worktree operation sparsify the operator's tree. `extensions.worktreeConfig=true` directs git to write `$repo/.git/worktrees/<name>/sparse-checkout` instead; the main checkout's sparsity is never touched.

**Pattern rationale:** `--no-cone` mode is required because cone mode cannot express negation patterns. The pattern `/* !/legacy/ /legacy/migrated/` includes everything by default, excludes the entire `legacy/` subtree, and re-includes `legacy/migrated/` so tombstones remain readable from within the worktree.

**Branch-switch retention:** Once sparse-checkout is set via `worktreeConfig`, it persists through `git checkout` calls inside the linked worktree. This is a property of git's mechanism, not something zBuild must actively maintain.

```scope
scripts/lib/worktree.sh
tests/unit/worktree-sparse-legacy-test.sh
docs/adr/ADR-059-issue-vs-run-keying.md
config/adr-enforcement-baseline.txt
tests/unit/worktree-location-test.sh
tests/integration/worktree-ownership-test.sh
tests/unit/legacy-e1-tombstone-test.sh
tests/integration/cleanup-cli-e2e-test.sh
tests/integration/intake-branch-held-diagnostic-test.sh
core/pipeline/runner.sh
```

```acceptance
SPEC-1[code]: after zbuild_worktree_acquire, the linked worktree contains no files under legacy/ except those under legacy/migrated/ covers: R-1 R-3 R-6
SPEC-2[code]: after zbuild_worktree_enter (create, adopt_local, or adopt_remote mode), the linked worktree contains no files under legacy/ except those under legacy/migrated/ covers: R-1 R-3 R-6
SPEC-3[code]: a git checkout inside a linked worktree (branch switch) does not restore legacy/ content — the sparse exclusion persists covers: R-1 R-6
SPEC-4[code]: a second zbuild_worktree_acquire call for an already-sparse worktree (resume path) retains the exclusion — legacy/ is still absent covers: R-1 R-6
SPEC-5[code]: the main checkout's core.sparseCheckout config is absent or false after sparse-checkout is applied to a linked worktree (extensions.worktreeConfig isolates per-worktree config) covers: R-2 R-4 R-5
SPEC-6[no-code]: ADR-059 §2 is amended to document the per-worktree sparse-checkout decision and the zbuild_worktree_include_legacy_path widening protocol for keeper PRs covers: R-1 R-2
SPEC-7[no-code]: ADR-059-issue-vs-run-keying.md is removed from config/adr-enforcement-baseline.txt and ADR-059 carries a valid ## Enforced by section naming tests/unit/worktree-sparse-legacy-test.sh covers: R-1
WIRING:
scripts/lib/worktree.sh
TESTFILES:
SPEC-1: tests/unit/worktree-sparse-legacy-test.sh
SPEC-2: tests/unit/worktree-sparse-legacy-test.sh
SPEC-3: tests/unit/worktree-sparse-legacy-test.sh
SPEC-4: tests/unit/worktree-sparse-legacy-test.sh
SPEC-5: tests/unit/worktree-sparse-legacy-test.sh
SPEC-6: docs/adr/ADR-059-issue-vs-run-keying.md
SPEC-7: config/adr-enforcement-baseline.txt
```

LOOP_COMPLETE
