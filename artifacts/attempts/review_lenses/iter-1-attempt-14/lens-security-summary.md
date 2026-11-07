## review-lens-security — fail

- found: medium: cycle_id is interpolated directly into the jq filter string passed to get_state_field, which uses `jq -r "$jq_path // \"$default\""` — if a template cycle ID contains a double-quote or jq metacharacter, the filter string is broken and arbitrary jq code executes. (core/pipeline/cycle-orchestrator.sh:2401) (and 4 more)

- medium: cycle_id is interpolated directly into the jq filter string passed to get_state_field, which uses `jq -r "$jq_path // \"$default\""` — if a template cycle ID contains a double-quote or jq metacharacter, the filter string is broken and arbitrary jq code executes. (core/pipeline/cycle-orchestrator.sh:2401)
- medium: _cyc_id (from _TPL_DISPATCH_UNITS, template-sourced) is interpolated into the jq path string passed to get_state_field without escaping; a crafted cycle ID containing `"` breaks the jq filter and can inject additional jq code read against pipeline-state.json. (core/pipeline/runner.sh:3529)
- medium: _ust (the stage name from _TPL_DISPATCH_UNITS, template-sourced) is interpolated into the jq filter string passed to get_state_field for the new stage:* skip guard; same jq-injection vector as the cycle:* arm above. (core/pipeline/runner.sh:3846)
- medium: In the new auto-resume-via-latest-symlink path, _runner_issue is read from the state file without numeric validation, while _runner_run_id in the same block is sanitised with //[^a-zA-Z0-9_.-]//; a crafted state file with a non-numeric issue value propagates an unsanitised string into event-log key=value pairs and git branch-name construction. (core/pipeline/runner.sh:2264)
- low: The path-traversal guard in _artifact_persist_put_back checks for `..` only when it appears at the start of rel or is followed by `/`; a path component ending in `..` (e.g. `foo/..`) passes the guard, resolving to the parent directory on cp. (core/state/artifact-persist.sh:646)
- score: 7
