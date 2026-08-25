# Design: Migrate test plugin to v2 result contract (issue #1836)

## Decision summary

**Goal:** Bring `plugins/tool/test` into conformance with ADR-054 §5 — the v2 result
file contract. This means: `result_contract: 2` at the top level; mandatory `disposition`
and `reason` fields at the top level; plugin-specific data nested under `data: {}`; signal
deaths mapped to `disposition=interrupted`; a `test_cleanup` release hook verified; no
artifact path construction in `_test_write_result`; and `valid_verdicts` declared in the
manifest.

**Context:** The test plugin was the last major `kind: tool` plugin on the v1 flat schema
(`schema_version: 1`, no `disposition`, no `data` block). Gate readers
(`coverage-gate`, `lint-gate`, `mutation-gate`, `gate-aggregator`) and the cycle
orchestrator read paths out of `test-results.json` that changed when data moved under
`data: {}`. ADR-054 §6 defines the closed `disposition` vocabulary; ADR-055 defines the
inter-stage data contract.

**Decision:** Migrate `_test_write_result` to the v2 shape; add `_test_disposition_from_rc`
to map `(rc, verdict) → disposition`; update all four gate readers and the orchestrator
to use the new `data.*` paths; declare `result_contract: 2` and `valid_verdicts` in the
manifest. Acceptance assertions are co-located in the existing `test-test.sh` (which
exists at baseline) so the acceptance gate can locate the file and prove each [change]
assertion fails against the baseline implementation.

```scope
plugins/tool/test/plugin.sh
plugins/tool/test/manifest.yaml
plugins/tool/test/tests/test-test.sh
plugins/tool/coverage-gate/plugin.sh
plugins/tool/gate-aggregator/plugin.sh
plugins/tool/lint-gate/plugin.sh
plugins/tool/mutation-gate/plugin.sh
core/pipeline/cycle-orchestrator.sh
tests/unit/convergence-timeouts-never-fatal-1208-test.sh
tests/unit/core-pipeline-cycle-final-gate-test.sh
tests/unit/core-pipeline-cycle-stall-break-test.sh
tests/unit/design-timeout-exhaustion-halt-1261-test.sh
tests/unit/framework-result-test.sh
tests/unit/test-plugin-empty-diff-test.sh
tests/unit/test-plugin-positional-args-test.sh
tests/unit/test-targeted-advisory-hint-test.sh
tests/unit/test-plugin-result-write-fallback-test.sh
docs/adr/ADR-054-stage-contract.md
```

```acceptance
SPEC-1[change]: result-results.json emits result_contract=2 at the top level (not schema_version:1)
SPEC-2[change]: disposition field is present at the top level of test-results.json on every code path
SPEC-3[change]: disposition=complete when verdict is pass
SPEC-4[change]: disposition=complete when verdict is fail (test ran to completion)
SPEC-5[change]: disposition=broken on the missing-diff-patch error path
SPEC-6[change]: reason=missing_diff_patch is emitted on the missing-diff error path
SPEC-7[change]: plugin-specific fields (exit_code, passed, failed, test_output, test_cmd, run_mode) live under data:{} not at the top level
SPEC-8[change]: _test_disposition_from_rc maps rc=130/137/143 (signal death) to interrupted, and other non-zero rc to broken
SPEC-9[guard]: _test_write_result does not construct artifact paths from artifact_dir internally (path is a caller arg)
SPEC-10[guard]: manifest valid_verdicts enumerates every verdict the plugin emits (pass, fail, error)
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
```

LOOP_COMPLETE
