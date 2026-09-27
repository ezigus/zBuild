# Design: Migrate validate plugin to contract v2

## Architectural Decision Summary

**Goal:** Adopt the ADR-054/ADR-055 v2 stage contract in `plugins/agent/validate`:
v2 result file shape (`result_contract:2`, `verdict`, `disposition`, `reason`, `data`),
disposition on every exit path, rc ∈ {0,1}, name-matched input resolution via
`ZBUILD_STAGE_INPUTS`, and `result_contract: 2` in the manifest `provides:` block.

**Context:** The validate plugin pre-migration writes result files with
`{"schema_version":1,"verdict":"..."}` on all exits — no `result_contract`,
`disposition`, or `reason`. It resolves the deploy-result path via a hardcoded
`$state_dir/artifacts/deploy-result.json` construction, never consulting
`ZBUILD_STAGE_INPUTS`. Three exit paths return `rc=2` (missing state_file, missing
deploy-result.json, missing health-check plugin); the health-probe failure path
propagates `$hc_rc` directly (may be >1). ADR-054 §4b mandates rc ∈ {0,1} for v2
plugins; ADR-054 §5 mandates the four mandatory result keys; ADR-055 §1 mandates
name-matched input resolution. The fail-closed probe-rc propagation (#757) must
be preserved.

ADR-058 C12 (#2211) — "the write boundary attributes by ownership, never by time" —
is noted context only: validate already writes only to its declared output path
(`$artifacts_dir/validate-result.json`), so no write-boundary changes are required.

ADR-003 (models-as-data) and ADR-032 (per-repo prompt overrides) were amended since
the prior design but do not affect this migration: validate makes no LLM calls.
ADR-003 is retained in scope as a reference for `tier_default: T2` confirmation only.

**Scope corrections from prior design:**
- `tests/integration/per-run-state-isolation-test.sh` is REMOVED from scope. That
  file uses a two-stage minimal template (intake → build) with mock plugins and
  neither sources the validate plugin nor places `deploy-result.json`.

**SPEC classification correction (iteration 2):** SPEC-17, SPEC-20, SPEC-22,
SPEC-23, SPEC-24, and SPEC-25 were tagged `[guard]` in the prior design and
flagged `guard_regressed` by the acceptance-gate.

Root cause: the v2 test file (rewritten entirely for this issue) calls
`_validate_agent_run_inner` at the SPEC-19 healthy-coverage section (line 292)
without `|| true`, under `set -euo pipefail`. At the merge-base, `_v2_run` places
`deploy-result.json` at `$dir/deploy-result.json` while the old plugin derives
`artifacts_dir` from `state_dir` and looks for `$dir/artifacts/deploy-result.json`;
the file is absent, so the function returns rc=2, which exits the test script before
SPEC-17, SPEC-20 through SPEC-25, SPEC-21, and SPEC-18 ever run. Those assertions
are therefore "not found" at the baseline — which the gate correctly treats as the
guard failing.

Fix: re-tag all six as `[change]`. Their assertions fail at the merge-base (by
never executing) and pass at HEAD (after the v2 input-resolution path is in place).
SPEC-19 remains correctly `[guard]`: its static manifest assertions execute and pass
before the script exits at line 292.

**Integration test wiring (open build failure):** `tests/integration/deployed-template-e2e-test.sh`
calls `validate_agent_run "validate" "$STATE_FILE"` but does not set `ZBUILD_STAGE_INPUTS`.
The v2 plugin's fallback `$(dirname "$state_file")/stage-inputs.json` does not exist in
that test environment, so the plugin returns rc=1 with "missing required input
deploy-result.json", breaking the dry-run path that was previously green. The build
stage must add a `ZBUILD_STAGE_INPUTS` export (a stage-inputs.json with
`.inputs.deploy_result` pointing to `$ARTIFACTS_DIR/deploy-result.json`) before the
`validate_agent_run` call, matching the pattern already established in `_make_state`
and `_v2_run` helpers in the unit test.

**Decision:** Rewrite `_validate_agent_run_inner` and `validate_agent_run` to write
v2 result files on every terminal exit, resolve inputs via `ZBUILD_STAGE_INPUTS`,
clamp all non-zero returns to rc=1, and add `result_contract: 2` to the manifest
`provides:` block. Tests are written first (red→green). `deployed-template-e2e-test.sh`
must export `ZBUILD_STAGE_INPUTS` before calling the validate plugin.

```scope
plugins/agent/validate/manifest.yaml
plugins/agent/validate/plugin.sh
plugins/agent/validate/tests/validate-test.sh
tests/integration/deployed-template-e2e-test.sh
tests/unit/sigpipe-antipattern-guard-test.sh
docs/wiki/plugins/validate.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/adr/ADR-017-per-stage-router-config.md
docs/adr/ADR-003-models-as-data.md
config/templates/deployed.yaml
scripts/lib/lint-disposition-words.sh
scripts/lib/lint-verdict-classify.sh
core/pipeline/disposition.sh
```

```acceptance
SPEC-14[change]: every terminal exit path of _validate_agent_run_inner writes a result file containing all four mandatory v2 keys — result_contract=2, verdict, disposition, and reason
SPEC-15[change]: manifest provides block carries result_contract: 2
SPEC-16[change]: plugin.sh resolves the deploy_result input path from ZBUILD_STAGE_INPUTS (jq .inputs.deploy_result) — no hardcoded $artifacts_dir/deploy-result.json path construction
SPEC-17[change]: a failed health probe (hc_rc != 0) causes validate_agent_run to return non-zero — the fail-closed invariant (#757) is exercised through the v2 ZBUILD_STAGE_INPUTS input-resolution path
SPEC-18[change]: all non-zero exits from plugin.sh use rc=1 — no exit path returns rc=2 or higher
SPEC-19[guard]: manifest config.valid_verdicts declares exactly [healthy, error]; validate-test.sh covers healthy and error via passing assertions
SPEC-20[change]: manifest has no config.router block — manifest_router_knob returns empty string for timeout_s and max_turns in the v2-migrated plugin (ADR-017)
SPEC-21[change]: a dry-run invocation with a valid deploy-result writes validate-result.json with result_contract=2, verdict=healthy, disposition=complete, reason present, and data={}; schema_version key is absent
SPEC-22[change]: manifest outputs array declares validate_result with primary: true — verified in the v2 test suite
SPEC-23[change]: manifest provides.role declares validate_agent — verified in the v2 test suite (#1704)
SPEC-24[change]: manifest provides.events declares exactly validate.input.missing and validate.probe.failed — verified in the v2 test suite (#1717)
SPEC-25[change]: manifest hooks block declares only run and no cleanup hook — verified in the v2 test suite (#1829)
WIRING: plugins/agent/validate/manifest.yaml
TESTFILES:
SPEC-14: plugins/agent/validate/tests/validate-test.sh
SPEC-15: plugins/agent/validate/tests/validate-test.sh
SPEC-16: plugins/agent/validate/tests/validate-test.sh
SPEC-17: plugins/agent/validate/tests/validate-test.sh
SPEC-18: plugins/agent/validate/tests/validate-test.sh
SPEC-19: plugins/agent/validate/tests/validate-test.sh
SPEC-20: plugins/agent/validate/tests/validate-test.sh
SPEC-21: plugins/agent/validate/tests/validate-test.sh
SPEC-22: plugins/agent/validate/tests/validate-test.sh
SPEC-23: plugins/agent/validate/tests/validate-test.sh
SPEC-24: plugins/agent/validate/tests/validate-test.sh
SPEC-25: plugins/agent/validate/tests/validate-test.sh
```

LOOP_COMPLETE
