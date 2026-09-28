## spec-coverage — uncovered

- The issue requires "behaviour is unchanged for a passing run" but no SPEC requires updating the integration test harness (`tests/integration/deployed-template-e2e-test.sh`) to supply `ZBUILD_ARTIFACT_DIR`, so the existing e2e test breaks after the migration removes the state-file-derived path.

- NOT COVERED: Behaviour is unchanged for a passing run — no SPEC covers updating the integration harness to set `ZBUILD_ARTIFACT_DIR`, causing the deployed-template-e2e test to fail once the plugin no longer derives its output path from the state file.
