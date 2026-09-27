## issue-acceptance — fail

- The plugin now requires `ZBUILD_STAGE_INPUTS` to locate `deploy-result.json`, but `tests/integration/deployed-template-e2e-test.sh` was not updated to supply it, causing `validate_agent_run` to error on the missing input even in dry-run, breaking the "behaviour is unchanged for a passing run" requirement.

- NOT MET: Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output
