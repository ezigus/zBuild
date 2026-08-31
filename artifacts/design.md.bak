# Design: Migrate test plugin to v2 result contract (issue #1836)

## Decision summary

**Goal:** Bring `plugins/tool/test` into conformance with ADR-054 §5 — the v2 result
file contract. This means: `result_contract: 2` at the top level; mandatory `disposition`
at the top level on every exit path; top-level shortcut fields (`exit_code`, `run_mode`,
`test_output`) duplicated at top level for direct consumers; plugin-specific data nested
under `data: {}`; signal deaths mapped to `disposition=interrupted`; a `test_cleanup`
release hook verified; no artifact path construction in `_test_write_result`; and
`valid_verdicts` declared in the manifest.

**Context:** The test plugin was the last major `kind: tool` plugin on the v1 flat schema
(`schema_version: 1`, no `disposition`, no `data` block). Gate readers
(`coverage-gate`, `lint-gate`, `mutation-gate`, `gate-aggregator`) and the cycle
orchestrator read paths out of `test-results.json` that moved under `data: {}` (e.g.
`.data.failed`, `.data.run_mode`, `.data.coverage`). ADR-054 §6 defines the closed
`disposition` vocabulary; ADR-055 defines the inter-stage data contract. Several companion
test files (positional-args, empty-diff, targeted-advisory-hint, fd-isolation, fresh-shell,
and committed-head tests) are updated in the same change to use `.data.*` field paths. The
fallback test and summary-format integration test carry the SPEC-11 assertion that
`run_mode` and `test_output` appear at the top level of v2 output (for direct consumers).

**Decision:** Migrate `_test_write_result` to the v2 shape with `result_contract: 2`,
mandatory `disposition`, and top-level shortcut copies of `exit_code`, `run_mode`, and
`test_output` alongside the canonical `data: {}` block (dual exposure — direct consumers
read the top-level shortcuts; structured consumers read `data.*`). Add
`_test_disposition_from_rc` to map `(rc, verdict) → disposition` (pass|fail → complete,
rc=130/137/143 → interrupted, other → broken). Update companion test files to use
`.data.*` paths and the v2 calling convention for `_test_write_result` (disposition at
position 3). Declare `result_contract: 2` and `valid_verdicts` in the manifest.
Acceptance assertions are co-located in `test-test.sh` (SPEC-1..10) and companion files
(SPEC-11) so the acceptance gate can prove each [change] assertion fails at baseline.

```scope
plugins/tool/test/plugin.sh
plugins/tool/test/manifest.yaml
plugins/tool/test/tests/test-test.sh
plugins/tool/coverage-gate/plugin.sh
plugins/tool/gate-aggregator/plugin.sh
plugins/tool/lint-gate/plugin.sh
plugins/tool/mutation-gate/plugin.sh
core/pipeline/cycle-orchestrator.sh
scripts/lib/proc-group.sh
tests/unit/convergence-timeouts-never-fatal-1208-test.sh
tests/unit/core-pipeline-cycle-final-gate-test.sh
tests/unit/core-pipeline-cycle-stall-break-test.sh
tests/unit/design-timeout-exhaustion-halt-1261-test.sh
tests/unit/framework-result-test.sh
tests/unit/test-plugin-empty-diff-test.sh
tests/unit/test-plugin-positional-args-test.sh
tests/unit/test-targeted-advisory-hint-test.sh
tests/unit/test-plugin-result-write-fallback-test.sh
tests/integration/test-plugin-summary-format-test.sh
tests/integration/test-plugin-fresh-shell-test.sh
tests/integration/test-plugin-runs-against-committed-head-test.sh
tests/integration/test-plugin-fd-isolation-test.sh
docs/adr/ADR-054-stage-contract.md
```

```acceptance
SPEC-1[change]: test_output is emitted at the top level of test-results.json for direct consumers (was absent at the top level in the v1 schema)
SPEC-2[change]: run_mode is emitted at the top level of test-results.json (was absent at the top level in v1)
SPEC-3[change]: exit_code=0 is present at the top level on the pass path and disposition=complete is set
SPEC-4[change]: exit_code=1 is present at the top level on the fail path and disposition=complete is set
SPEC-5[change]: test_output is present at the top level on the error path and disposition=broken is set on the missing-diff error
SPEC-6[change]: run_mode is present at the top level on the missing-diff error path and reason=missing_diff_patch is emitted
SPEC-7[change]: exit_code appears both at the top level and under data.exit_code in the same artifact
SPEC-8[change]: _test_disposition_from_rc maps rc=130/137/143 (signal death) to interrupted and other non-zero rc to broken; test_output is present at top level confirming the v2 shape
SPEC-9[guard]: _test_write_result does not reference artifact_dir internally — path is supplied entirely by the caller
SPEC-10[guard]: manifest valid_verdicts enumerates every verdict the plugin emits: pass, fail, and error
SPEC-11[change]: top-level shortcut fields (run_mode, test_output) appear in the v2 writer output and in integration scenarios driven by companion test files
WIRING: none
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
SPEC-11: tests/unit/test-plugin-result-write-fallback-test.sh tests/integration/test-plugin-summary-format-test.sh
```

LOOP_COMPLETE
