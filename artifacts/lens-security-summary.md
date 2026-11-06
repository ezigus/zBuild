## review-lens-security — pass

- found: low: _runner_run_id read from the persisted state file via get_state_field is never sanitised before being interpolated into event-bus fields; a crafted state file whose .run_id contains spaces or equals signs would split the event record into extra phantom fields. (core/pipeline/runner.sh) (and 3 more)

- low: _runner_run_id read from the persisted state file via get_state_field is never sanitised before being interpolated into event-bus fields; a crafted state file whose .run_id contains spaces or equals signs would split the event record into extra phantom fields. (core/pipeline/runner.sh)
- low: In _runner_from_stage_preflight the variable name built for indirect expansion uses only dash-to-underscore substitution, leaving characters such as ], [, and . intact; bash interprets arrayname[n] syntax inside indirect expansion, so a cycle name containing ] could resolve to a different array element than intended. (core/pipeline/runner.sh)
- low: export _ZBUILD_RESUME_ACTIVE=true makes the engine internal resume flag visible to every child process including plugin run hooks; a plugin that reads this variable can silently alter its behaviour on resume, creating an undocumented side-channel between the engine and plugin code. (core/pipeline/runner.sh)
- low: The guard in _artifact_persist_put_back rejects absolute rel values but does not reject rel paths beginning with ../; a directory containing a symlink whose find output after prefix-stripping starts with .. could bypass the check and write outside the destination tree. (core/state/artifact-persist.sh:644)
- score: 8
