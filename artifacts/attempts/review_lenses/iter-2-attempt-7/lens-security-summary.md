## review-lens-security — fail

- found: medium: The new `_artifact_persist_put_back` function guards against absolute-path injection (`/* `) but not against relative dotdot traversal (`../`), so a `rel` value of `../../outside/the/target` would pass the check and write outside `$to`. (core/state/artifact-persist.sh:644) (and 1 more)

- medium: The new `_artifact_persist_put_back` function guards against absolute-path injection (`/* `) but not against relative dotdot traversal (`../`), so a `rel` value of `../../outside/the/target` would pass the check and write outside `$to`. (core/state/artifact-persist.sh:644)
- low: `--from-stage` accepts any string without validating it against a stage-name character set before the value is embedded in a variable name used for indirect expansion (`${!_fsp_cycle_stages_var:-}`) and in a `warn`/`echo` message to stderr. (core/pipeline/runner.sh:1800)
- score: 8
