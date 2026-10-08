## Review Report

**Merge Readiness:** needs_attention

1 of 6 lens(es) did not run (sre) — their review is missing, not clean. 6 merge-readiness finding(s) across 6 lens(es) (0 critical, 0 high).

> **Advisory:** Some lenses did not run, so this report is incomplete; re-run the review before merging. Advisory only — this does not block the pipeline.

### Lens Findings

#### correctness (score: 7/10)
- [low] scripts/lib/worktree.sh:299 — _zbuild_worktree_apply_sparse silences all stderr from both git calls with 2>/dev/null, unlike every other git invocation in the file which captures and prints error output; when either command fails the caller receives rc=5 with no diagnostic, making the failure opaque to operators.
- [low] scripts/lib/worktree.sh:312 — zbuild_worktree_include_legacy_path does not validate that $path starts with 'legacy/', so a caller passing an arbitrary path (e.g. 'src/' or an absolute path) would silently widen the sparse set beyond the stated contract of a legacy source for keeper PRs.
- [medium] tests/unit/worktree-sparse-legacy-test.sh:147 — SPEC-4 fixture creates a worktree via plain 'git worktree add --detach' with no sparse-checkout configured, but SPEC-4 requires the pre-condition to be a worktree that already has sparse-checkout configured; the re-apply-over-existing-sparse scenario (idempotency) is not exercised by the test.

#### performance (score: 9/10)
- [low] scripts/lib/worktree.sh:299 — \`git -C "$repo_root" config extensions.worktreeConfig true\` is called on every worktree acquisition including the reuse/resume path, but \`extensions.worktreeConfig\` is a repository-wide setting that only needs to be written once; re-writing the same value on every resume is O(n) in the number of runs per issue where O(1) would suffice.

#### red-team (score: 6/10)
- [medium] scripts/lib/worktree.sh:312 — zbuild_worktree_include_legacy_path calls \`git -C "$wt" sparse-checkout add "$path"\` without a \`--\` end-of-options separator, so a caller-supplied path beginning with \`--\` (e.g., \`--cone\`) is interpreted by git as a flag rather than a pattern — \`--cone\` would switch the worktree from no-cone mode to cone mode, silently destroying the \`!/legacy/\` negation patterns and re-enabling full legacy/ materialisation for that worktree.
- [low] scripts/lib/worktree.sh:299 — \`git -C "$repo_root" config extensions.worktreeConfig true\` permanently writes to the main checkout's \`.git/config\` and is never reverted, even after all linked worktrees are removed; a repo owner who had deliberately set \`extensions.worktreeConfig=false\` would have that overridden silently with no mechanism to restore it.
- [low] tests/unit/worktree-sparse-legacy-test.sh:145 — The SPEC-4 resume-path fixture creates a worktree with no sparse config at all, not one that already has sparse-checkout configured as the spec requires; the test therefore does not verify that \`sparse-checkout set\` overwrites an existing conflicting pattern rather than merging with it, leaving a gap if a future git version changes merge semantics.

#### scope (score: 10/10)
No findings.

#### security (score: 8/10)
- [medium] scripts/lib/worktree.sh:312 — \`zbuild_worktree_include_legacy_path\` passes the \`path\` argument directly to \`git sparse-checkout add "$path"\` without validating that it begins with \`legacy/\` or that it does not contain git pattern syntax (\`!\`, \`*\`); a caller passing \`/legacy/\` would re-include the entire frozen tree, \`/*!/*\` would disable the exclusion entirely, and \`!/legacy/migrated/\` would remove tombstone visibility — this change introduces the public API with no guard.
- [low] scripts/lib/worktree.sh:299 — Both git commands in \`_zbuild_worktree_apply_sparse\` redirect stderr to \`/dev/null\`; if \`git sparse-checkout set\` fails (version incompatibility, corrupted worktree metadata, filesystem permission), there is no diagnostic output and operators cannot determine why a worktree was left non-sparse, reducing security auditability.

#### sre (score: 0/10)
No findings.


### Merge-Readiness Findings (de-duped)
- [low] scripts/lib/worktree.sh:299 — Both git commands in \`_zbuild_worktree_apply_sparse\` redirect stderr to \`/dev/null\`; if \`git sparse-checkout set\` fails (version incompatibility, corrupted worktree metadata, filesystem permission), there is no diagnostic output and operators cannot determine why a worktree was left non-sparse, reducing security auditability. _(lenses: security)_
- [medium] scripts/lib/worktree.sh:312 — \`zbuild_worktree_include_legacy_path\` passes the \`path\` argument directly to \`git sparse-checkout add "$path"\` without validating that it begins with \`legacy/\` or that it does not contain git pattern syntax (\`!\`, \`*\`); a caller passing \`/legacy/\` would re-include the entire frozen tree, \`/*!/*\` would disable the exclusion entirely, and \`!/legacy/migrated/\` would remove tombstone visibility — this change introduces the public API with no guard.; zbuild_worktree_include_legacy_path calls \`git -C "$wt" sparse-checkout add "$path"\` without a \`--\` end-of-options separator, so a caller-supplied path beginning with \`--\` (e.g., \`--cone\`) is interpreted by git as a flag rather than a pattern — \`--cone\` would switch the worktree from no-cone mode to cone mode, silently destroying the \`!/legacy/\` negation patterns and re-enabling full legacy/ materialisation for that worktree. _(lenses: red-team, security)_
- [low] scripts/lib/worktree.sh:299 — _zbuild_worktree_apply_sparse silences all stderr from both git calls with 2>/dev/null, unlike every other git invocation in the file which captures and prints error output; when either command fails the caller receives rc=5 with no diagnostic, making the failure opaque to operators.; \`git -C "$repo_root" config extensions.worktreeConfig true\` permanently writes to the main checkout's \`.git/config\` and is never reverted, even after all linked worktrees are removed; a repo owner who had deliberately set \`extensions.worktreeConfig=false\` would have that overridden silently with no mechanism to restore it. _(lenses: correctness, red-team)_
- [low] scripts/lib/worktree.sh:312 — zbuild_worktree_include_legacy_path does not validate that $path starts with 'legacy/', so a caller passing an arbitrary path (e.g. 'src/' or an absolute path) would silently widen the sparse set beyond the stated contract of a legacy source for keeper PRs. _(lenses: correctness)_
- [low] scripts/lib/worktree.sh:299 — \`git -C "$repo_root" config extensions.worktreeConfig true\` is called on every worktree acquisition including the reuse/resume path, but \`extensions.worktreeConfig\` is a repository-wide setting that only needs to be written once; re-writing the same value on every resume is O(n) in the number of runs per issue where O(1) would suffice. _(lenses: performance)_
- [medium] tests/unit/worktree-sparse-legacy-test.sh:145 — SPEC-4 fixture creates a worktree via plain 'git worktree add --detach' with no sparse-checkout configured, but SPEC-4 requires the pre-condition to be a worktree that already has sparse-checkout configured; the re-apply-over-existing-sparse scenario (idempotency) is not exercised by the test.; The SPEC-4 resume-path fixture creates a worktree with no sparse config at all, not one that already has sparse-checkout configured as the spec requires; the test therefore does not verify that \`sparse-checkout set\` overwrites an existing conflicting pattern rather than merging with it, leaving a gap if a future git version changes merge semantics. _(lenses: correctness, red-team)_

