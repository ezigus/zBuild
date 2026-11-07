## review-lens-security — fail

- found: high: `_runner_run_id` read from the new latest-symlink auto-resume state file is not sanitized, while the fresh-run path explicitly strips unsafe characters to prevent path traversal via `ZBUILD_RUN_ID` in filenames; two plugins use `ZBUILD_RUN_ID` directly in path constructions. (core/pipeline/runner.sh:2227) (and 2 more)

- high: `_runner_run_id` read from the new latest-symlink auto-resume state file is not sanitized, while the fresh-run path explicitly strips unsafe characters to prevent path traversal via `ZBUILD_RUN_ID` in filenames; two plugins use `ZBUILD_RUN_ID` directly in path constructions. (core/pipeline/runner.sh:2227)
- medium: The path returned by `readlink -f "$state_dir/latest"` is assigned as `state_dir` with no check that it remains within the expected state root; an adversary who controls the `latest` symlink redirects all artifact operations, `ZBUILD_STATE_DIR` exports, and `mkdir` calls to an arbitrary filesystem location. (core/pipeline/runner.sh:2223)
- low: `_artifact_persist_put_back` guards only against an absolute `rel` (the prefix-strip failure case) but not against `..` components; a hostile git state branch that places a file at a path whose stripped relative form begins with `../` could write outside the artifact directory, and the new resume rehydration call site adds a second consumer of this gap. (core/state/artifact-persist.sh:644)
- score: 6
