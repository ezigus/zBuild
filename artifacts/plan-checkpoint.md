## Checkpoint — issue #1921 plan (final)

### Files read and key findings

- `core/state/artifact-persist.sh:295` — `_artifact_persist_push` exists; line 312 checks `refs/heads/$branch` locally before pushing. Line 313-315: if branch missing → status="empty", reason="no local branch...to push (nothing was snapshotted)", returns 0. Origin push at 324.
- `core/state/artifact-persist.sh:340` — `_artifact_persist_restore` prefers local branch; falls back to `refs/remotes/origin/$branch` (line 365-366) for CI cold-start.
- `plugins/tool/persist/plugin.sh:86-157` — `persist_run`: (1) calls `_artifact_persist_snapshot` (line 102) → sets `_snapshot`; (2) secret gate; (3) calls `_artifact_persist_push` → sets `_pushed`; (4) writes persist-result.json with `{verdict, reason, data:{snapshot, pushed}}`.
- `.github/workflows/zbuild-pipeline.yml:165` — `ZBUILD_STATE_DIR=$RUNNER_TEMP/zbuild-state` set in env. Lines 235-243: push step only checks if local state branch exists, does NOT read persist-result.json.
- `tests/unit/persist-stage-test.sh:161-166` — tests credential-refused case only; no assertion on `data.snapshot` field; no test for successful push writing snapshot=saved.
- `tests/unit/artifact-persist-test.sh` — has restore tests (T4, T7, T14) but all use local-to-local fixture; no test for restore from `refs/remotes/origin/` (CI path).

### Conclusions

1. Code is correct — push function exists and is called by persist plugin.
2. persist-result.json has snapshot+pushed fields; nothing in CI reads them to surface in job log → acceptance criterion 1 not met.
3. CI path for restore (`refs/remotes/origin/` fallback) is untested.
4. No test asserts `data.snapshot` is set correctly in persist-result.json.
5. Stale `origin/zbuild/state/issue-4244` exists (pre-fix test residue).

### Plan (final)

Step 1: `.github/workflows/zbuild-pipeline.yml` — Add "Surface persist result" always-run step after "Push work branch". Finds persist-result.json under $ZBUILD_STATE_DIR via `find`, reads with jq, emits ::notice:: fields. ~25 lines.
Step 2: `.github/workflows/zbuild-pipeline.yml` — Add "Delete stale test-residue state branch" step deleting origin/zbuild/state/issue-4244. ~12 lines.
Step 3: `tests/unit/artifact-persist-test.sh` — Add T-CI-restore test: bare remote + local fetch into refs/remotes/origin/... → _artifact_persist_restore reads it. ~40 lines.
Step 4: `tests/unit/persist-stage-test.sh` — Add assertions on data.snapshot field. ~20 lines.
