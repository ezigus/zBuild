# Design: Migrate test plugin to contract v2 (issue #1836)

## Decision

**Goal.** Bring `plugins/tool/test` into compliance with the ADR-054 §5 result contract: emit `result_contract:2`, mandatory `disposition` and `reason` fields, `disposition=interrupted` on SIGTERM, confirmed `release` hook semantics, and a `valid_verdicts` set that covers every verdict the plugin writes.

**Context.** Twenty-five plugins still speak v1 (schema_version:1, no disposition, no reason). Phase-0 migrations (#1833–#1849) move them one at a time. The test plugin is `plugins/tool/test`. It currently writes `schema_version:1` at the top level with plugin-specific scalars (exit_code, passed, failed, test_output, diff_applied, test_cmd, run_mode, timing, tree_sha, lint, coverage, mutation) also at the top level. After migration the result file carries the four mandatory v2 top-level fields (`result_contract`, `verdict`, `disposition`, `reason`) and moves all plugin-specific data under `data:{}`. Every consumer that reads a top-level field from test-results.json is therefore also in scope.

**Decision.**
1. `_test_write_result` emits `result_contract:2` instead of `schema_version:1`; adds mandatory `disposition` and `reason`; relocates plugin-specific scalars under `data`.
2. `_test_disposition_from_rc` helper maps exit code to disposition (`complete` for pass/fail, `interrupted` for signal deaths, `broken` for all other non-success paths).
3. The degenerate fallback JSON (PIPESTATUS[0]!=0) also gets `result_contract:2` and `disposition=broken`.
4. `manifest.yaml` gains `result_contract: 2` under `provides:`.
5. Consumers of top-level fields from test-results.json (`cycle-orchestrator.sh`, `gate-aggregator`, `coverage-gate`, `lint-gate`, `mutation-gate`) update their jq paths to read under `data`.
6. Test stubs that write test-results.json fixtures update to the v2 shape.

```scope
plugins/tool/test/manifest.yaml
plugins/tool/test/plugin.sh
plugins/tool/test/tests/test-test.sh
plugins/tool/test/tests/parse-unit-test.sh
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/wiki/plugins/test.md
core/contract/version.sh
core/pipeline/disposition.sh
core/pipeline/verdict.sh
core/pipeline/cycle-orchestrator.sh
plugins/tool/gate-aggregator/plugin.sh
plugins/tool/coverage-gate/plugin.sh
plugins/tool/lint-gate/plugin.sh
plugins/tool/mutation-gate/plugin.sh
tests/unit/gate-aggregator-test.sh
tests/unit/core-pipeline-cycle-final-gate-test.sh
tests/unit/design-timeout-exhaustion-halt-1261-test.sh
tests/unit/convergence-timeouts-never-fatal-1208-test.sh
tests/unit/core-pipeline-cycle-stall-break-test.sh
tests/unit/test-plugin-empty-diff-test.sh
tests/unit/test-plugin-positional-args-test.sh
tests/unit/framework-result-test.sh
tests/unit/test-targeted-advisory-hint-test.sh
tests/unit/core-pipeline-verdict-test.sh
tests/unit/core-pipeline-disposition-test.sh
tests/unit/lint-verdict-classify-test.sh
tests/unit/artifact-type-retirement-test.sh
tests/unit/cycle-orchestrator-capability-flags-test.sh
tests/integration/test-stage-proc-group-test.sh
tests/integration/cycle-blocked-real-artifact-test.sh
```

```acceptance
SPEC-1[change]: result file contains result_contract:2 (not schema_version:1) on the normal pass/fail path
SPEC-2[change]: result file contains mandatory disposition field on every execution path (pass/fail/error/missing-diff/silent-failure/summary-unavailable)
SPEC-3[change]: result file contains mandatory reason field on every execution path
SPEC-4[change]: test subprocess killed by SIGTERM (rc=143) writes disposition=interrupted in the result file
SPEC-5[change]: test_cleanup release scope kills the staging process group and leaves the staging directory on disk (does not rm -rf)
SPEC-6[change]: plugin.sh contains no artifact path construction from manifest plugin-id strings in code (static grep assertion)
SPEC-7[change]: manifest provides.result_contract is 2 and config.valid_verdicts covers every verdict string the plugin writes
SPEC-8[guard]: existing pass verdict path still produces verdict=pass with disposition=complete
SPEC-9[guard]: existing fail verdict path still produces verdict=fail with disposition=complete
SPEC-10[guard]: existing error verdict paths (missing_diff_patch, silent_failure, summary_unavailable) retain their reason strings
WIRING: plugins/tool/test/manifest.yaml
TESTFILES:
SPEC-1: plugins/tool/test/tests/test-test.sh
SPEC-2: plugins/tool/test/tests/test-test.sh
SPEC-3: plugins/tool/test/tests/test-test.sh
SPEC-4: plugins/tool/test/tests/test-test.sh
SPEC-5: plugins/tool/test/tests/test-test.sh
SPEC-6: plugins/tool/test/tests/test-test.sh
SPEC-7: plugins/tool/test/tests/test-test.sh
SPEC-8: plugins/tool/test/tests/test-test.sh
SPEC-9: plugins/tool/test/tests/test-test.sh
SPEC-10: plugins/tool/test/tests/test-test.sh
```
