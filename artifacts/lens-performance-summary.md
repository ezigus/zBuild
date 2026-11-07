## review-lens-performance — fail

- found: medium: In the dispatch loop's stage:* resume arm, `_verdict_primary_output_path` and `_verdict_resolve_path` are called via `$()` subshells for every complete stage, even though the no-subshell `_v` variants (`_verdict_primary_output_path_v`, `_verdict_resolve_path_v`) exist for this exact purpose (ADR-065 §5); each complete stage forks two unnecessary subshells on the resume startup path. (core/pipeline/runner.sh:3801) (and 3 more)

- medium: In the dispatch loop's stage:* resume arm, `_verdict_primary_output_path` and `_verdict_resolve_path` are called via `$()` subshells for every complete stage, even though the no-subshell `_v` variants (`_verdict_primary_output_path_v`, `_verdict_resolve_path_v`) exist for this exact purpose (ADR-065 §5); each complete stage forks two unnecessary subshells on the resume startup path. (core/pipeline/runner.sh:3801)
- medium: In `_runner_from_stage_preflight`, `_verdict_primary_output_path` and `_verdict_resolve_path` are called via `$()` for every pre-target stage, forking two subshells per stage when the `_v` variants would avoid all forks. (core/pipeline/runner.sh:1764)
- low: `get_state_field` calls `validate_json` (a `jq empty` fork) followed by a second `jq -r` fork on the same unchanged state file for every dispatch unit in resume mode; with N units, this forks 2N jq processes during resume startup before any stage runs. (core/pipeline/runner.sh:3790)
- low: On the first resumed iteration, up to four jq subprocesses are forked per complete cycle member (status read, verdict read, blob-entry construction, blob update); the state file and `$blob` could be read once before the member loop and updated in-memory instead. (core/pipeline/cycle-orchestrator.sh:1444)
- score: 7
