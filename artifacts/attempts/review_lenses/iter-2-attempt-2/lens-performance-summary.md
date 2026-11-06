## review-lens-performance — fail

- found: high: `cycle_dispatch_stage` emits a flock-protected `stage.start` disk write on every cycle-member dispatch at every iteration of every fresh run, not only during resume, because the guard `_cd_iter > 0` is always true for cycle-member calls. (core/pipeline/runner.sh:3204) (and 3 more)

- high: `cycle_dispatch_stage` emits a flock-protected `stage.start` disk write on every cycle-member dispatch at every iteration of every fresh run, not only during resume, because the guard `_cd_iter > 0` is always true for cycle-member calls. (core/pipeline/runner.sh:3204)
- medium: `_runner_from_stage_preflight` calls `_find_plugin_for_stage` (which runs `discover_plugins_into` — a full plugin-directory scan reading every manifest) in a command substitution for each stage before the target, so for N pre-target stages there are N full plugin-directory scans (O(N×P) manifest reads) on the `--from-stage` startup path. (core/pipeline/runner.sh:1757)
- medium: `get_state_field` is called once per top-level dispatch unit (cycle:* and stage:*) during resume; each call spawns two subprocesses — `jq empty` for validation plus `jq -r` for the read — re-reading and re-validating the same state file for every unit instead of loading the status map once at resume entry. (core/pipeline/runner.sh:3482)
- low: The SPEC-2 stale-artifact check inside the stage:* dispatch arm forks three subprocesses (`_find_plugin_for_stage`, `_verdict_primary_output_path`, `_verdict_resolve_path`) for each top-level stage that is marked complete during resume; `_find_plugin_for_stage` itself re-scans the entire plugin directory each time. (core/pipeline/runner.sh:3775)
- score: 5
