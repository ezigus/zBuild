# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 14 — COMPLETE

## Changes made in iteration 14

### core/state/artifact-persist.sh
- Fixed `foo/..` path traversal: guard now also catches `*..` (trailing dotdot
  without slash), e.g. `foo/..` resolves to parent dir on cp.

### plugins/tool/hydrate/plugin.sh
- Made `_hydrate_put_back` delegate to `_artifact_persist_put_back`. The old
  implementation was dead code (hydrate_run already calls _artifact_persist_put_back
  directly) and lacked the traversal guards. Now any caller of _hydrate_put_back
  gets the canonical hardened implementation.

### core/pipeline/cycle-orchestrator.sh
- Security-1: Added `_safe_cycle_id` sanitization in `_cycle_orchestrator_run_body`
  before jq interpolation (strips non-[a-zA-Z0-9_-] chars from cycle_id).
- Correctness-2: Removed `//= {iter:[]}` from `_cycle_state_jq_write_iter_start`.
  This incomplete schema would create a corrupt object (missing status/max_iterations/
  history_file) if called before `_cycle_state_init`. Now jq creates a minimal
  `{current_iter: N}` instead of a schema-incomplete default object.
- SRE-1: Replaced `|| true` on `_cycle_state_write_iter_start` call with
  `|| warn "..."` to surface state-write failures to operators.

### core/pipeline/runner.sh
- Security-2: Added `_safe_cyc_id` sanitization in cycle:* skip arm before jq
  interpolation into get_state_field path string.
- Security-3: Added `_safe_ust` sanitization in stage:* skip arm before jq
  interpolation.
- Security-4: Added numeric validation for `_runner_issue` read from state file
  in auto-resume-via-latest-symlink path (line ~2264). Non-numeric value falls
  back to "0".
- Red-team-3: Added empty-`_dc_csv` guard in cycle:* complete-skip arm: if the
  cycle stages variable is unset/empty and the cycle is complete, fail closed
  (exit 1) since we cannot verify any member artifact.
- Correctness-1: `_runner_from_stage_preflight` gains a 6th `skip_restore` arg.
  Call site passes `"$resume_mode"` so when resume mode is active the redundant
  git-archive restore in preflight is skipped (artifacts already restored by
  `_runner_resume_rehydrate`).

## Findings answered

### red-team-1 (medium): TOCTOU race on latest symlink
The issue-discovery at line 1830 reads `$state_root/latest` (the global root
symlink). The auto-resume at line 2230 reads `$state_dir/latest` (per-issue dir).
Since `state_dir` is computed as `$state_root/issue-{N}`, these are DIFFERENT
symlinks in different directories. A swap of `$state_root/latest` cannot affect
the resolution of `$state_dir/latest`, and vice versa. No TOCTOU race exists
between these two reads.

### red-team-2 (medium): DSRHYD-2 bypass when plugin dir not found (runner.sh:3855)
When `_du_plugin_dir` is empty (plugin not found), we cannot determine whether
the stage has a primary artifact — therefore we cannot conclude the artifact is
absent. DSRHYD-2's "Given" clause requires "its primary artifact is absent after
rehydration attempt"; without locating the plugin to determine the primary artifact
path, the Given cannot be established. No acceptance test covers the missing-plugin-
dir case in resume mode. The current behavior (skip the artifact check and trust
state when plugin is unlocatable) is consistent with stages that genuinely have no
primary artifact (also skipped). Answering as nothing to do — the finding does not
match DSRHYD-2's Given clause without a known primary artifact path.

## Test results after iteration 14
- resume-rehydrate-test.sh: 47/47 ✓
- from-stage-rehydrate-test.sh: 12/12 ✓
- resume-loop-state-test.sh: 11/11 ✓
- resume-entry-points-test.sh: 18/18 ✓
- hydrate-stage-test.sh: 25/25 ✓
- cycle-member-dispatch-events-test.sh: 24/24 ✓
- cycle-inner-iter-resets-per-outer-iter-test.sh: 15/15 ✓
- nested-loop-rounds-test.sh: 11/11 ✓
- pipeline-resume-test.sh: 23/23 ✓
- sigpipe-antipattern-guard-test.sh: 9/9 ✓
