## issue-acceptance — fail

- No SPEC required that all integration-test callers invoking `validate_agent_run` through the runner be updated to supply `ZBUILD_STAGE_INPUTS`; `per-run-state-isolation-test.sh` fails in the full suite because the plugin now resolves its input from `/dev/null` when the variable is absent, where it previously fell back to the hardcoded path.

- NOT MET: Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output
