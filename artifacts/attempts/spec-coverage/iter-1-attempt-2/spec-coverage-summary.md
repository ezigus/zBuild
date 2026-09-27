## spec-coverage — uncovered

- The issue's "behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output" requires integration-level verification, but all 12 SPECs map exclusively to `plugins/agent/validate/tests/validate-test.sh`; `tests/integration/deployed-template-e2e-test.sh` is listed in design scope but no SPEC covers it, leaving the v2 `ZBUILD_STAGE_INPUTS` input-resolution path untested at integration level.

- NOT COVERED: Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output (no SPEC exercises the integration test path
- NOT COVERED: the integration test failure on "missing required input deploy-result.json" is the direct consequence)
