## Checkpoint — issue #1921 plan

### Files read and key findings

- `core/state/artifact-persist.sh`: `_artifact_persist_push` (line 295) exists, pushes zbuild/state/issue-N to origin with --force. `_artifact_persist_snapshot` creates local ref. `_artifact_persist_restore` checks refs/remotes/origin/$branch as fallback (CI path — line 365-366).
- `plugins/tool/persist/plugin.sh:130`: calls `_artifact_persist_push`; uses `warn` for failures (visible in "Run pipeline" CI log output). Writes persist-result.json.
- `.github/workflows/zbuild-pipeline.yml`: 
  - Lines 118-140: fetches state branch into refs/remotes/origin/zbuild/state/issue-N (for restore)
  - Lines 210-243: "Push work branch" step (always()) also pushes state branch — redundant with persist plugin now, but harmless defense-in-depth
  - Checkout at line 76: uses actions/checkout@v7 with NO fetch-depth (defaults to 1, shallow)
  - permissions: contents:write — push should be authorized
- `tests/unit/persist-stage-test.sh:161`: uses ZBUILD_ISSUE_NUMBER=4244 with a credential in artifact → push REFUSED by secret gate. So current test does NOT push to origin. Stale origin branch is pre-fix residue.

### Conclusions

1. The code is CORRECT — `_artifact_persist_push` exists and is called. ADR-059 Phase 2 is in.
2. No shallow-clone bug — git plumbing (hash-object, write-tree, commit-tree, update-ref) all work on shallow clones.
3. The remaining work is VERIFICATION + DIAGNOSTICS:
   - Acceptance criterion 1: snapshot outcome needs explicit ::notice:: in CI job log (not just zbuild warn to stderr)
   - The stale origin/zbuild/state/issue-4244 needs manual deletion (pre-code)
   - Need test for the CI restore path (refs/remotes/origin/ fallback)
4. The CI push step (lines 235-243) is now redundant with persist plugin but harmless.

### Next if stopped now

Plan: 
Step 1 — `.github/workflows/zbuild-pipeline.yml`: add "Surface persist result" step (if: always()) that reads ZBUILD_STATE_DIR/artifacts/persist/persist-result.json and emits ::notice:: + ::warning:: annotations. ~25 lines.
Step 2 — `.github/workflows/zbuild-pipeline.yml`: add one-time cleanup step that deletes origin/zbuild/state/issue-4244 if it exists. ~10 lines.
Step 3 — `tests/unit/artifact-persist-unit-test.sh`: add test for restore from refs/remotes/origin/ fallback (CI cold-start path). ~30 lines.
Step 4 — `tests/unit/persist-stage-test.sh`: assert snapshot field in persist-result.json is "saved" (not just "pushed=false"). ~15 lines.
