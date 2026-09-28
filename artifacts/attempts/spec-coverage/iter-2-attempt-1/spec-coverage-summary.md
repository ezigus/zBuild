## spec-coverage — uncovered

- SPEC-5 covers only the `scope_manifest` path; the acceptance criterion "the plugin constructs no artifact paths in code" is universal, but no SPEC asserts that other inputs previously resolved by hardcoded path (e.g. `source: artifacts` or `source: cycle_feedback` inputs) have been removed from `plugin.sh`.

- NOT COVERED: The plugin constructs no artifact paths in code — SPEC-5 tests a single named input (scope_manifest via ZBUILD_STAGE_INPUTS)
- NOT COVERED: all other artifact paths the plugin may still construct manually have no corresponding SPEC requiring their removal
