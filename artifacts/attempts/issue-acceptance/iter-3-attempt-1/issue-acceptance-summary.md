## issue-acceptance — fail

- The issue requires behaviour to be unchanged for a passing run, but `per-run-state-isolation-test.sh` was not updated to supply `ZBUILD_STAGE_INPUTS`; the plugin now resolves its deploy-result path from `/dev/null` when the variable is absent, silently breaking that caller, and no SPEC required updating all integration-test callers of `validate_agent_run`.

- NOT MET: Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output
