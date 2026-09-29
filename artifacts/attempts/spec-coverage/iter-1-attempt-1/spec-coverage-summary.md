## spec-coverage — uncovered

- The issue explicitly requires deleting the runner's rc=10 leaf-path branch (`core/pipeline/runner.sh:3471-3487`) and either removing or recording the justification for the manifest's `router.retries: 1` and `router.retry_on_exhaustion: 1` knobs; no SPEC demands either change.

- NOT COVERED: `runner.sh:3471-3487` rc=10 branch must be deleted — SPEC-3 only tests the plugin's output (rc=1 + plan.json), not the runner code removal
- NOT COVERED: `router.retries:1` and `router.retry_on_exhaustion:1` must be removed or their retention explicitly recorded — SPEC-9 names `max_turns` and `timeout_s` only.
