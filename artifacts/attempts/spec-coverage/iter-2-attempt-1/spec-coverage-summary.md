## spec-coverage — uncovered

- SPEC-14 covers only the case where `$ZBUILD_STAGE_INPUTS` is set and doesn't prove the hardcoded `$artifacts_dir/deploy-result.json` / `pr-url.txt` path construction is deleted from `plugin.sh`, and no SPEC covers `provides.events`/`provides.role` declaration.

- NOT COVERED: "plugin constructs no artifact paths in code — assert by grep over its plugin.sh" (SPEC-14 only tests the resolved-path behavior when inputs are set, leaving the hardcoded-path fallback unaddressed)
- NOT COVERED: `provides.events` declared (#1717)
- NOT COVERED: `provides.role` declared (#1704)
