## issue-acceptance — fail

- The v2 ZBUILD_STAGE_INPUTS input-resolution path was not wired into the integration test environment, so the dry-run path that was previously green now errors on "missing required input deploy-result.json" — breaking the "behaviour is unchanged for a passing run" requirement and leaving `npm test` red.

- NOT MET: Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output
- NOT MET: `npm test` green
