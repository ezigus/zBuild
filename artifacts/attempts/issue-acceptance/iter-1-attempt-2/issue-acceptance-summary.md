## issue-acceptance — fail

- `per-run-state-isolation-test.sh` calls `validate_agent_run` without setting `ZBUILD_STAGE_INPUTS`; the plugin now resolves the deploy-result path from `/dev/null`, finds no input, and exits non-zero where it previously succeeded — the diff updated `deployed-template-e2e-test.sh` but missed this second caller.

- NOT MET: behaviour unchanged for a passing run — a before/after golden diff on the stage's own output
