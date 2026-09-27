## issue-acceptance — fail

- The migration to ZBUILD_STAGE_INPUTS for deploy-result path resolution broke per-run-state-isolation-test.sh, which calls the validate plugin without setting ZBUILD_STAGE_INPUTS; the plugin now resolves to `/dev/null`, finds no deploy_result, and exits 1 where it previously succeeded, violating the "behaviour unchanged for a passing run" acceptance criterion.

- NOT MET: behaviour unchanged for a passing run — per-run-state-isolation-test.sh (a previously-passing integration scenario, issue #887) now fails because callers that do not set ZBUILD_STAGE_INPUTS receive a broken-input error exit instead of the healthy outcome the old hardcoded-path code produced
