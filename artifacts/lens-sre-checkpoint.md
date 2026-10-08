# SRE Lens Checkpoint — Issue #1802

## Files read
- scripts/lib/worktree.sh: full file — new _zbuild_worktree_apply_sparse and zbuild_worktree_include_legacy_path; called at 4 sites (acquire new, acquire reuse, enter reuse, enter new)
- tests/unit/worktree-sparse-legacy-test.sh: full file — tests SPEC-1 through SPEC-5; no test for zbuild_worktree_include_legacy_path
- docs/adr/ADR-059-issue-vs-run-keying.md partial (§2 new text)

## Conclusions

1. **Silent failure / no diagnostic** (high, introduced): `_zbuild_worktree_apply_sparse` suppresses both git calls with `2>/dev/null`. Callers get rc=5 from acquire/enter with no stderr explaining which step failed (config write vs sparse-checkout set). Operator has zero observability into the failure reason.

2. **No git version guard** (medium, introduced): `git sparse-checkout` requires git ≥ 2.25. On older git, all worktree acquisition fails hard with rc=5 and no explanation. Not documented, no graceful degradation.

3. **`set` overwrites `add` widening on resume** (high, introduced): `_zbuild_worktree_apply_sparse` calls `git sparse-checkout set` (REPLACE semantics). `zbuild_worktree_include_legacy_path` calls `git sparse-checkout add`. On resume of a keeper PR run, `_zbuild_worktree_apply_sparse` is called again and overwrites the widening — the keeper can no longer access the legacy path. This makes the widening protocol unreliable for multi-stage runs that are interrupted and resumed.

4. **No test for zbuild_worktree_include_legacy_path** (medium, introduced): The keeper PR widening function ships with zero test coverage, including no test for the resume-overwrite scenario.

5. **Permanent repo config mutation** (low, introduced): `extensions.worktreeConfig=true` written to target repo `.git/config` on every acquisition; irreversible side effect, no rollback path documented.

## Unresolved
- Whether zbuild_worktree_include_legacy_path is intended to be called only once per run (before `git rm`) with no resume possible — would make finding #3 theoretical rather than practical.

## What I would do next
- Emit the final JSON now.
