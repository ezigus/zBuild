## issue-acceptance — fail

- The diff migrates the deploy-result path resolution to `ZBUILD_STAGE_INPUTS` and updates `deployed-template-e2e-test.sh` to supply it, but leaves `per-run-state-isolation-test.sh` without the variable, so that caller silently falls back to `/dev/null` and the plugin's missing-input guard fires — breaking a previously-passing run; no SPEC required updating all existing callers of `validate_agent_run`.

- NOT MET: Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output
